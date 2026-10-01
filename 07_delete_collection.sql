-- Removes all data for ONE collection (a stat_collect_job id) across
-- the 11 hist_* tables, then the stat_collect_job row itself (must be
-- last -- the hist_* tables FK to it). Returns rows deleted per table.
--   SELECT * FROM <schema>.delete_collection(9);
-- Requires -v schema=<name>.

CREATE OR REPLACE FUNCTION :"schema".delete_collection(p_job_id bigint)
RETURNS TABLE(table_name text, rows_deleted bigint)
LANGUAGE plpgsql
AS $func$
DECLARE
    v_context text;
    v_schema  text;
    v_tbl     text;
    v_count   bigint;
BEGIN
    -- Self-detects the schema it was deployed into (see 03_fdw_setup.sql's
    -- header) rather than hardcoding it, so this file works under any
    -- -v schema= value without further changes to its body.
    GET DIAGNOSTICS v_context = PG_CONTEXT;
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
    END IF;
    EXECUTE format('SET search_path = %I', v_schema);

    FOREACH v_tbl IN ARRAY ARRAY[
        'hist_pg_stat_database', 'hist_pg_stat_database_conflicts',
        'hist_pg_statio_all_tables', 'hist_pg_statio_all_indexes',
        'hist_pg_stat_all_tables', 'hist_pg_stat_statements', 'hist_pg_stat_statements_info',
        'hist_schemas', 'hist_object_size', 'hist_tables_size', 'hist_index_poor'
    ] LOOP
        EXECUTE format('DELETE FROM %I WHERE id_stat_collect_job = $1', v_tbl)
            USING p_job_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        table_name := v_tbl;
        rows_deleted := v_count;
        RETURN NEXT;
    END LOOP;

    DELETE FROM stat_collect_job WHERE id = p_job_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'stat_collect_job';
    rows_deleted := v_count;
    RETURN NEXT;
END;
$func$;

ALTER FUNCTION :"schema".delete_collection(bigint) OWNER TO stats_collect_owner;
