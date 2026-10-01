-- =====================================================================
-- Release 0.4.2 migration -- see releases.yaml. Applied automatically
-- by `./deploy.py --migrate` against an already-deployed environment;
-- run directly with psql only if you're not using deploy.py:
--
--   psql <connection target> -v schema=stats_collect -f migrations/0004_schema_detection_search_path.sql
--
-- Run it as a role allowed to replace these routines: their owner, or a
-- role with that owner's privileges (CREATE OR REPLACE needs ownership).
--
-- WHY: collect_stats(), setup_instance_fdw(), refresh_instance_fdw()
-- and delete_collection() took their schema from PG_CONTEXT with the
-- regexp 'function ([^.]+)\.'. PL/pgSQL leaves the schema out of that
-- signature when it is on the search_path the routine was compiled
-- with, which is what happens under pg_cron when the owner role's
-- search_path includes the schema: v_schema came out NULL and
-- SET search_path failed with "null values cannot be formatted as an
-- SQL identifier". 03_fdw_setup.sql, 04_collect_procedure.sql and
-- 07_delete_collection.sql now resolve the signature with
-- to_regprocedure() instead.
--
-- HOW: instead of re-running those files (which would also reset each
-- routine's owner to the name hardcoded there), this replaces only the
-- detection line inside each live routine definition and re-creates it
-- with CREATE OR REPLACE, which keeps its current owner and grants.
-- A routine that already has the new detection is left alone, so this
-- can run more than once; an unexpected definition aborts everything.
-- =====================================================================

BEGIN;

SELECT set_config('stats_collect_migration.schema', :'schema', true);

DO $do$
DECLARE
    v_schema  name := current_setting('stats_collect_migration.schema');
    -- The old line, in either quoting ('...\.' or E'...\\.').
    v_old_re  text := $re$\n[ \t]*v_schema := \(regexp_match\(v_context, E?'function \(\[\^\.\]\+\)\\{1,2}\.'\)\)\[1\];$re$;
    v_new     text := $new$
    -- First context line = this routine's own signature, schema-qualified
    -- only when its schema isn't on the search_path it was compiled with
    -- (e.g. pg_cron runs as a role whose search_path includes it).
    -- to_regprocedure() resolves either form to this routine.
    SELECT n.nspname INTO v_schema
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE p.oid = to_regprocedure(substring(split_part(v_context, E'\n', 1) FROM E'(\\S+\\(.*\\))'));
    IF v_schema IS NULL THEN
        RAISE EXCEPTION 'could not detect this routine''s schema from PG_CONTEXT: %', v_context;
    END IF;$new$;
    v_marker  text := 'to_regprocedure(substring(split_part(v_context';
    v_name    text;
    v_oid     oid;
    v_owner   name;
    v_def     text;
    v_match   text;
BEGIN
    FOREACH v_name IN ARRAY ARRAY['collect_stats', 'setup_instance_fdw', 'refresh_instance_fdw', 'delete_collection'] LOOP
        SELECT p.oid, pg_get_userbyid(p.proowner) INTO v_oid, v_owner
            FROM pg_proc AS p
            JOIN pg_namespace AS n ON n.oid = p.pronamespace
            WHERE n.nspname = v_schema AND p.proname = v_name;
        IF v_oid IS NULL THEN
            RAISE EXCEPTION '%.% not found -- is -v schema= right?', v_schema, v_name;
        END IF;

        v_def := pg_get_functiondef(v_oid);
        IF strpos(v_def, v_marker) > 0 THEN
            RAISE NOTICE '%.%: already has the new schema detection, skipped', v_schema, v_name;
            CONTINUE;
        END IF;

        v_match := substring(v_def FROM v_old_re);
        IF v_match IS NULL THEN
            RAISE EXCEPTION '%.%: old schema detection line not found, nothing replaced', v_schema, v_name;
        END IF;
        IF NOT pg_has_role(current_user, v_owner, 'USAGE') THEN
            RAISE EXCEPTION '%.% is owned by %, which % cannot act as', v_schema, v_name, v_owner, current_user
                USING HINT = 'Run this migration as the routines'' owner.';
        END IF;

        EXECUTE replace(v_def, v_match, v_new);

        IF strpos(pg_get_functiondef(v_oid), v_marker) = 0 THEN
            RAISE EXCEPTION '%.%: replacement did not take effect', v_schema, v_name;
        END IF;
        RAISE NOTICE '%.%: schema detection replaced (owner % kept)', v_schema, v_name, v_owner;
    END LOOP;
END
$do$;

COMMIT;
