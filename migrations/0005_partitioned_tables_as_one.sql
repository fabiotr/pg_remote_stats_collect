-- =====================================================================
-- Release migration -- see releases.yaml. Applied automatically by
-- `./deploy.py --migrate` against an already-deployed environment;
-- run directly with psql only if you're not using deploy.py:
--
--   psql <connection target> -v schema=stats_collect -f migrations/0005_partitioned_tables_as_one.sql
--
-- WHY: hist_tables_size collected the instance's top 10 *physical*
-- tables by size, one row per table -- a partitioned table never
-- appeared as itself (relkind 'p' was excluded), only whichever of its
-- individual partitions happened to rank, so a large partitioned table
-- (e.g. one with dozens of monthly partitions) showed up as a handful
-- of its biggest partitions, massively under-representing its true
-- size and growth. collect_stats()'s hist_tables_size query now rolls
-- up every partition (any depth, via pg_inherits) to its top-level
-- ancestor and sizes it as one table, and the row limit goes from 10 to
-- 20 -- rpt_tables_size_history_raw (06_reports.sql) already ranks
-- "rn <= 20", so this also makes that pre-existing limit meaningful
-- instead of a no-op against a 10-row source.
--
-- HOW: re-creates collect_stats() with CREATE OR REPLACE, which keeps
-- its existing owner and grants -- nothing else needs touching. Every
-- other routine/table is unaffected; hist_tables_size's columns don't
-- change, only which rows get inserted going forward (existing history
-- stays as collected, still a valid partial view of the partitioned
-- tables it captured before this release).
--
-- Also (re)installs copy_top_statements(), first added in 0.4.1 --
-- that release's own migration is null, so an environment that reached
-- 0.4.1 purely through `--migrate` (never had 04_collect_procedure.sql
-- run against it directly) never actually got this helper, even though
-- collect_stats() has called it since. Without it, every instance's
-- collection in this procedure fails and rolls back. CREATE OR REPLACE
-- is a no-op if it's already there and keeps its owner in that case; on
-- an environment where it's genuinely missing, it's created owned by
-- whoever runs this migration -- same as any other first-time
-- migration-created object.
--
-- UPDATE (folded in before this release ever shipped to a real
-- environment -- see releases.yaml's 0.4.4 entry): the rollup CTE
-- below originally required visibility (pg_table_is_visible()) on the
-- top-level ancestor itself, walking DOWN from there via pg_inherits.
-- Whenever that one ancestor wasn't visible on the connection's
-- search_path (its own schema not on it, or its name shadowed by
-- another schema earlier on it) -- even though its partitions/children
-- were -- the whole subtree silently disappeared from hist_tables_size,
-- not just the obscured ancestor.
--
-- UPDATE 2 (also folded in before any real environment saw it): the
-- first fix above anchored purely on visible, storage-bearing leaves
-- and walked UP via pg_inherits, which swapped the bug for its mirror
-- image -- a tree whose root WAS visible but whose individual
-- partitions happened to live in a schema that wasn't now had those
-- partitions silently excluded from its total (understating it), or
-- disappeared entirely if every one of its partitions was like that.
-- The rollup now determines which roots are in scope from visibility
-- ANYWHERE in the tree -- either the root itself is visible, or at
-- least one leaf's walk-up reaches it -- and only then walks DOWN
-- from each in-scope root with NO visibility check at all, since an
-- individual partition's own schema visibility was never what made
-- its bytes part of the application's data, only the tree's
-- eligibility as a whole was.
--
-- hist_tables_size also gains an is_rollup column (always true going
-- forward): 0.4.3 changes what total_size *means* for any table that
-- turns out to be a rollup root -- from "this one relation" to "the
-- whole subtree" -- under the same (instance, schema, name) key a
-- prior release may already have a row for. Without a way to tell the
-- two methodologies apart, rpt_tables_size_history_raw's month/year
-- growth columns (06_reports.sql) would read that one-time jump as
-- real growth. Existing rows are backfilled to false so the growth
-- window (partitioned by is_rollup, among other things) starts a new,
-- unconnected series at the first rollup-scoped row instead.
-- =====================================================================

BEGIN;

ALTER TABLE :"schema".hist_tables_size ADD COLUMN IF NOT EXISTS is_rollup boolean;
UPDATE :"schema".hist_tables_size SET is_rollup = false WHERE is_rollup IS NULL;
ALTER TABLE :"schema".hist_tables_size ALTER COLUMN is_rollup SET NOT NULL;
ALTER TABLE :"schema".hist_tables_size ALTER COLUMN is_rollup SET DEFAULT true;

CREATE OR REPLACE FUNCTION :"schema".copy_top_statements(
    p_source_table text,
    p_job_id bigint,
    p_instance :"schema".instance_name,
    p_limit int DEFAULT 100
) RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
    v_schema    name := current_schema();
    v_cols      text;
    v_order_by  text;
    v_has_split boolean;
BEGIN
    SELECT bool_or(column_name = 'total_plan_time') INTO v_has_split
    FROM information_schema.columns
    WHERE table_schema = v_schema AND table_name = p_source_table;
    v_order_by := CASE WHEN v_has_split THEN 'total_plan_time + total_exec_time' ELSE 'total_time' END;

    SELECT string_agg(
        CASE WHEN fc.column_name IS NOT NULL THEN quote_ident(tc.column_name)
             ELSE format('NULL::%s', tc.data_type)
        END, ', ' ORDER BY tc.ordinal_position)
    INTO v_cols
    FROM information_schema.columns tc
    LEFT JOIN information_schema.columns fc
        ON fc.table_schema = v_schema AND fc.table_name = p_source_table
            AND fc.column_name = tc.column_name
    WHERE tc.table_schema = v_schema AND tc.table_name = 'hist_pg_stat_statements'
        AND tc.column_name NOT IN ('id_stat_collect_job', 'instance');

    EXECUTE format(
        'INSERT INTO hist_pg_stat_statements SELECT %L::bigint, %L::%I.instance_name, %s FROM %I ORDER BY %s DESC NULLS LAST LIMIT %s',
        p_job_id, p_instance::text, v_schema, v_cols, p_source_table, v_order_by, p_limit);
END;
$func$;

CREATE OR REPLACE PROCEDURE :"schema".collect_stats()
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_context   text;
    v_schema    name;
    v_job_id    bigint;
    v_inst      record;
    v_inst_err  text;
    v_version   numeric;
BEGIN
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

    v_job_id := nextval(pg_get_serial_sequence('stat_collect_job', 'id'));

    RAISE NOTICE '[collect_stats] job % started', v_job_id;

    FOR v_inst IN SELECT * FROM instance_config WHERE enabled ORDER BY instance LOOP
        v_inst_err := NULL;
        v_version := NULL;
        RAISE NOTICE '[collect_stats] % - starting', v_inst.instance;

        INSERT INTO stat_collect_job (id, instance, collect_start, status)
        VALUES (v_job_id, v_inst.instance, clock_timestamp(), 'running');
        COMMIT;

        BEGIN

        SELECT t.version INTO v_version
        FROM dblink(v_inst.fdw_server, $sql_version$
            SELECT current_setting('server_version_num')::numeric
        $sql_version$) AS t(version numeric);

        PERFORM copy_matching_columns('pg_stat_database_' || v_inst.instance, 'hist_pg_stat_database', v_job_id, v_inst.instance);
        PERFORM copy_matching_columns('pg_stat_database_conflicts_' || v_inst.instance, 'hist_pg_stat_database_conflicts', v_job_id, v_inst.instance);
        PERFORM copy_matching_columns('pg_statio_all_tables_' || v_inst.instance, 'hist_pg_statio_all_tables', v_job_id, v_inst.instance);
        PERFORM copy_matching_columns('pg_statio_all_indexes_' || v_inst.instance, 'hist_pg_statio_all_indexes', v_job_id, v_inst.instance);
        PERFORM copy_matching_columns('pg_stat_all_tables_' || v_inst.instance, 'hist_pg_stat_all_tables', v_job_id, v_inst.instance);
        PERFORM copy_top_statements('pg_stat_statements_' || v_inst.instance, v_job_id, v_inst.instance);

        -- skipped for a pre-1.9 instance -- setup_instance_fdw() never created it
        IF to_regclass(quote_ident('pg_stat_statements_info_' || v_inst.instance)) IS NOT NULL THEN
            PERFORM copy_matching_columns('pg_stat_statements_info_' || v_inst.instance, 'hist_pg_stat_statements_info', v_job_id, v_inst.instance);
        END IF;

        -- ---- raw queries via dblink ----

        INSERT INTO hist_schemas
        SELECT v_job_id, v_inst.instance, s.*
        FROM dblink(v_inst.fdw_server, $sql_schemas$
            SELECT
                nspname,
                size,
                round(size / pg_database_size(current_database()) * 100, 4) AS size_pct,
                tables, indexes, p_tables, p_indexes, m_views, toast, sequences, views, types, foreign_tables
            FROM (
                SELECT
                    n.nspname,
                    SUM(pg_relation_size(c.oid)) AS size,
                    count(*) FILTER (WHERE c.relkind = 'r') AS tables,
                    count(*) FILTER (WHERE c.relkind = 'i') AS indexes,
                    count(*) FILTER (WHERE c.relkind = 'p') AS p_tables,
                    count(*) FILTER (WHERE c.relkind = 'I') AS p_indexes,
                    count(*) FILTER (WHERE c.relkind = 'm') AS m_views,
                    count(*) FILTER (WHERE c.relkind = 't') AS toast,
                    count(*) FILTER (WHERE c.relkind = 'S') AS sequences,
                    count(*) FILTER (WHERE c.relkind = 'v') AS views,
                    count(*) FILTER (WHERE c.relkind = 'c') AS types,
                    count(*) FILTER (WHERE c.relkind = 'f') AS foreign_tables
                FROM pg_class c
                    JOIN pg_namespace n ON c.relnamespace = n.oid
                WHERE n.nspname NOT LIKE 'pg_temp_%'
                    AND n.nspname NOT LIKE 'pg_toast_temp_%'
                GROUP BY n.nspname
            ) t
            ORDER BY size DESC
        $sql_schemas$) AS s(
            nspname name, size bigint, size_pct numeric, tables bigint, indexes bigint,
            p_tables bigint, p_indexes bigint, m_views bigint, toast bigint,
            sequences bigint, views bigint, types bigint, foreign_tables bigint
        );

        INSERT INTO hist_object_size
        SELECT v_job_id, v_inst.instance, s.*
        FROM dblink(v_inst.fdw_server, $sql_objsize$
            SELECT
                coalesce(t.spcname, nullif(current_setting('default_tablespace'),''), 'pg_default') AS tablespace,
                n.nspname AS schema,
                c.relname AS name,
                CASE c.relkind
                    WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view'
                    WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' WHEN 's' THEN 'special'
                    WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partition table'
                END AS type,
                pg_get_userbyid(c.relowner) AS owner,
                pg_table_size(c.oid) AS size,
                c.reltuples AS rows
            FROM pg_class c
                LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
                LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','p','i','I','v','m','S','f','')
                AND c.relpersistence != 't'
                AND n.nspname NOT IN ('pg_catalog','information_schema')
                AND n.nspname !~ '^pg_toast'
                AND pg_catalog.pg_table_is_visible(c.oid)
            ORDER BY pg_table_size(c.oid) DESC
            LIMIT 20
        $sql_objsize$) AS s(
            tablespace text, schema name, name name, type text, owner name,
            size bigint, rows real
        );

        INSERT INTO hist_tables_size
        SELECT v_job_id, v_inst.instance, s.*
        FROM dblink(v_inst.fdw_server, $sql_tblsize$
            WITH RECURSIVE ancestry AS (
                -- Walk UP the inheritance chain (any depth) from every
                -- non-temp, visible table/materialized view/
                -- partitioned-or-inherited parent toward its top-level
                -- ancestor, whatever that ancestor's own visibility
                -- happens to be. Includes 'p' (not just the 'r'/'m'
                -- that actually have storage): an intermediate
                -- partitioned table in a multi-level tree can be the
                -- ONLY visible member of that tree (its own parent and
                -- every physical leaf under it both invisible), and
                -- excluding it here would make eligible_roots' second
                -- branch below never discover that tree at all, same
                -- as not walking up from it in the first place. Plain
                -- UNION (not ALL): classic multiple inheritance (not
                -- partitioning, which is single-parent) can put more
                -- than one parent above the same starting point, which
                -- would otherwise walk the same (start_oid,
                -- ancestor_oid) pair more than once.
                SELECT c.oid AS start_oid, c.oid AS ancestor_oid
                FROM pg_class c
                    LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r','m','p')
                    AND c.relpersistence != 'temporary'
                    AND n.nspname <> 'information_schema'
                    AND n.nspname !~ '^pg_toast'
                    AND pg_table_is_visible(c.oid)
                UNION
                SELECT a.start_oid, i.inhparent
                FROM pg_inherits i
                    JOIN ancestry a ON i.inhrelid = a.ancestor_oid
            ),
            eligible_roots AS (
                -- A root is in scope if EITHER half finds it:
                -- visibility anywhere in its tree is enough to bring
                -- the whole tree into scope, not just visibility at
                -- one specific member of it. First half: the
                -- top-level ancestor is itself visible and isn't
                -- itself a partition/child of something else --
                -- catches a tree every one of whose partitions
                -- happens to live in a schema that isn't visible,
                -- even though the root (table name administrators
                -- actually look for) is. Second half: ancestry above
                -- already walked up from SOME visible member of the
                -- tree (a physical leaf or an intermediate partitioned
                -- table) to this same root -- catches a tree whose
                -- root isn't visible even though something under it
                -- is.
                SELECT c.oid AS root_oid
                FROM pg_class c
                    LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r','m','p')
                    AND c.relpersistence != 'temporary'
                    AND n.nspname <> 'information_schema'
                    AND n.nspname !~ '^pg_toast'
                    AND pg_table_is_visible(c.oid)
                    AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
                UNION
                SELECT DISTINCT a.ancestor_oid AS root_oid
                FROM ancestry a
                WHERE NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = a.ancestor_oid)
            ),
            descend AS (
                -- Once a root is in scope (by either rule above),
                -- every physical descendant under it counts toward
                -- its size -- walk DOWN unconditionally, with no
                -- visibility check at all: an individual partition's
                -- own schema visibility was never what made its bytes
                -- part of the application's data, only the tree's
                -- eligibility as a whole was. Plain UNION for the same
                -- double-counting reason as ancestry above.
                SELECT root_oid, root_oid AS oid FROM eligible_roots
                UNION
                SELECT d.root_oid, i.inhrelid
                FROM pg_inherits i
                    JOIN descend d ON i.inhparent = d.oid
            ),
            leaves AS (
                -- Only relkind 'r'/'m' descendants have storage of
                -- their own -- a partitioned/inheritance parent
                -- (relkind 'p') is a catalog-only placeholder with no
                -- physical size, so it never contributes its own row
                -- here, only its leaves'.
                SELECT d.root_oid, leaf.oid AS leaf_oid, leaf.reltoastrelid, leaf.reltuples
                FROM descend d
                    JOIN pg_class leaf ON leaf.oid = d.oid
                WHERE leaf.relkind IN ('r','m')
            ),
            top_roots AS (
                -- Rank by total_size and keep only the top 20 *before*
                -- computing index/heap/toast/row breakdowns below --
                -- pg_indexes_size()/pg_relation_size()/pg_table_size()
                -- each cost a stat() per leaf, so a heavily-partitioned
                -- table that doesn't make the cut shouldn't pay for
                -- them. Every supported PostgreSQL version materializes
                -- this CTE as written: pre-12 always did (no inlining
                -- existed yet), and this one is referenced only once,
                -- which keeps 12+ from having a reason to inline it
                -- either -- so avoid the MATERIALIZED keyword (12+
                -- only) rather than lean on that.
                SELECT root_oid, sum(pg_total_relation_size(leaf_oid)) AS total_size
                FROM leaves
                GROUP BY root_oid
                ORDER BY total_size DESC
                LIMIT 20
            )
            SELECT
                coalesce(t.spcname, nullif(current_setting('default_tablespace'),''), 'pg_default') AS tablespace,
                n.nspname AS schema,
                c.relname AS name,
                CASE c.relkind WHEN 'r' THEN 'table' WHEN 'm' THEN 'materialized view' WHEN 'p' THEN 'partitioned table' END AS type,
                CASE c.relpersistence WHEN 'p' THEN 'permanent' WHEN 'u' THEN 'unlogged' END AS persistence,
                pg_get_userbyid(c.relowner) AS owner,
                tr.total_size,
                sum(pg_indexes_size(l.leaf_oid)) AS index_size,
                round(100 * sum(pg_indexes_size(l.leaf_oid)) / nullif(tr.total_size,0), 2) AS index_size_pct,
                sum(pg_relation_size(l.leaf_oid,'main')) AS heap_size,
                round(100 * sum(pg_relation_size(l.leaf_oid,'main')) / nullif(tr.total_size,0), 2) AS heap_size_pct,
                sum(CASE WHEN l.reltoastrelid <> 0 THEN pg_table_size(l.reltoastrelid) ELSE 0 END) AS toast_size,
                round(100 * sum(CASE WHEN l.reltoastrelid <> 0 THEN pg_table_size(l.reltoastrelid) ELSE 0 END)
                    / nullif(tr.total_size,0), 2) AS toast_size_pct,
                -- reltuples = -1 means "never vacuumed/analyzed", not
                -- zero rows -- summing it in would silently understate
                -- the total instead of just leaving it unknown, so any
                -- unanalyzed leaf makes both of these NULL instead.
                CASE WHEN bool_or(l.reltuples < 0) THEN NULL ELSE sum(l.reltuples) END AS rows,
                CASE WHEN bool_or(l.reltuples < 0) THEN NULL
                    ELSE trunc(sum(pg_table_size(l.leaf_oid)) / nullif(sum(l.reltuples),0))::numeric
                END AS avg_row_size,
                true AS is_rollup
            FROM top_roots tr
                JOIN leaves l ON l.root_oid = tr.root_oid
                JOIN pg_class c ON c.oid = tr.root_oid
                LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
                LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            GROUP BY tr.root_oid, tr.total_size, t.spcname, n.nspname, c.relname, c.relkind, c.relpersistence, c.relowner
            ORDER BY tr.total_size DESC
            LIMIT 20
        $sql_tblsize$) AS s(
            tablespace text, schema name, name name, type text, persistence text,
            owner name, total_size bigint, index_size bigint, index_size_pct numeric,
            heap_size bigint, heap_size_pct numeric, toast_size bigint,
            toast_size_pct numeric, rows real, avg_row_size numeric, is_rollup boolean
        );

        INSERT INTO hist_index_poor
        SELECT v_job_id, v_inst.instance, s.*
        FROM dblink(v_inst.fdw_server, $sql_idxpoor$
            WITH table_scans AS (
                SELECT relid,
                    tables.idx_scan + tables.seq_scan AS all_scans,
                    (tables.n_tup_ins + tables.n_tup_upd + tables.n_tup_del) AS writes,
                    pg_relation_size(relid) AS table_size
                FROM pg_stat_user_tables AS tables
            ),
            all_writes AS (
                SELECT sum(writes) AS total_writes FROM table_scans
            ),
            indexes AS (
                SELECT idx_stat.relid, idx_stat.indexrelid,
                    idx_stat.schemaname, idx_stat.relname AS tablename,
                    idx_stat.indexrelname AS indexname,
                    idx_stat.idx_scan,
                    pg_relation_size(idx_stat.indexrelid) AS index_bytes,
                    indexdef ~* 'USING btree' AS idx_is_btree
                FROM pg_stat_user_indexes AS idx_stat
                    JOIN pg_index USING (indexrelid)
                    JOIN pg_indexes AS indexes
                        ON idx_stat.schemaname = indexes.schemaname
                            AND idx_stat.relname = indexes.tablename
                            AND idx_stat.indexrelname = indexes.indexname
                WHERE pg_index.indisunique = FALSE
            ),
            index_ratios AS (
                SELECT schemaname, tablename, indexname,
                    idx_scan, all_scans,
                    round((CASE WHEN all_scans = 0 THEN 0.0::numeric ELSE idx_scan::numeric/all_scans * 100 END), 2) AS index_scan_pct,
                    writes,
                    round((CASE WHEN writes = 0 THEN idx_scan::numeric ELSE idx_scan::numeric/writes END), 2) AS scans_per_write,
                    index_bytes,
                    table_size,
                    idx_is_btree
                FROM indexes JOIN table_scans USING (relid)
            ),
            index_groups AS (
                SELECT 'Never Used Indexes' AS reason, *, 1 AS grp FROM index_ratios
                WHERE idx_scan = 0 AND idx_is_btree
                UNION ALL
                SELECT 'Low Scans, High Writes' AS reason, *, 2 AS grp FROM index_ratios
                WHERE scans_per_write <= 1 AND index_scan_pct < 10 AND idx_scan > 0 AND writes > 100 AND idx_is_btree
                UNION ALL
                SELECT 'Seldom Used Large Indexes' AS reason, *, 3 AS grp FROM index_ratios
                WHERE index_scan_pct < 5 AND scans_per_write > 1 AND idx_scan > 0 AND idx_is_btree AND index_bytes > 100000000
                UNION ALL
                SELECT 'High-Write Large Non-Btree' AS reason, index_ratios.*, 4 AS grp
                FROM index_ratios, all_writes
                WHERE (writes::numeric / (total_writes + 1)) > 0.02 AND NOT idx_is_btree AND index_bytes > 100000000
            )
            SELECT reason, schemaname, tablename, indexname,
                idx_scan, all_scans, index_scan_pct, writes, scans_per_write,
                index_bytes AS index_size, table_size, idx_is_btree, grp
            FROM index_groups
            WHERE index_bytes > 1000000
            ORDER BY grp, index_bytes DESC, tablename, indexname, schemaname
            LIMIT 20
        $sql_idxpoor$) AS s(
            reason text, schemaname name, tablename name, indexname name,
            idx_scan bigint, all_scans bigint, index_scan_pct numeric, writes bigint,
            scans_per_write numeric, index_size bigint, table_size bigint,
            idx_is_btree boolean, grp int
        );

        EXCEPTION WHEN OTHERS THEN
            v_inst_err := format('SQLSTATE %s: %s', SQLSTATE, SQLERRM);
        END;

        IF v_inst_err IS NOT NULL THEN
            RAISE NOTICE '[collect_stats] % - FAILED: %', v_inst.instance, v_inst_err;
            UPDATE stat_collect_job
            SET collect_end = clock_timestamp(), status = 'failed', version = v_version, errors = ARRAY[v_inst_err]
            WHERE id = v_job_id AND instance = v_inst.instance;
        ELSE
            RAISE NOTICE '[collect_stats] % - done', v_inst.instance;
            UPDATE stat_collect_job
            SET collect_end = clock_timestamp(), status = 'succeeded', version = v_version
            WHERE id = v_job_id AND instance = v_inst.instance;
        END IF;

        COMMIT; -- outside the exception block above -- required
    END LOOP;

    RAISE NOTICE '[collect_stats] job % finished - % instance(s) with errors',
        v_job_id,
        (SELECT count(*) FROM stat_collect_job WHERE id = v_job_id AND status = 'failed');
END;
$proc$;

-- --------------------------------------------------------------------
-- 06_reports.sql's rpt_tables_size_history_raw/rpt_tables_size_history
-- aren't re-run by `./deploy.py --migrate` (only this file is), so the
-- is_rollup-aware growth window has to be applied here too for an
-- already-deployed environment to actually get it -- a fresh deploy
-- gets it straight from 06_reports.sql instead. CREATE OR REPLACE VIEW
-- can't reorder or drop existing output columns, only append new ones,
-- which is why is_rollup is added at the very end of both views'
-- column lists instead of next to total_size where it reads better --
-- 06_reports.sql matches that same order so the two never drift apart.
-- --------------------------------------------------------------------
SET search_path = :"schema";

CREATE OR REPLACE VIEW rpt_tables_size_history_raw AS
WITH latest_job AS (
    SELECT h.instance, max(h.id_stat_collect_job) AS id_stat_collect_job
    FROM hist_tables_size h
        JOIN instance_config ic ON ic.instance = h.instance
    WHERE ic.cluster = ic.instance
    GROUP BY h.instance
),
top_tables AS (
    SELECT instance, schema, name
    FROM (
        SELECT
            h.instance,
            h.schema,
            h.name,
            row_number() OVER (PARTITION BY h.instance ORDER BY h.total_size DESC) AS rn
        FROM hist_tables_size h
            JOIN latest_job lj
                ON lj.instance = h.instance AND lj.id_stat_collect_job = h.id_stat_collect_job
    ) ranked
    WHERE rn <= 20
),
history AS (
    SELECT
        j.collect_start::date AS collect_date,
        h.instance,
        h.tablespace,
        h.schema,
        h.name,
        h.type,
        h.persistence,
        h.owner,
        h.total_size,
        h.index_size,
        h.index_size_pct,
        h.heap_size,
        h.heap_size_pct,
        h.toast_size,
        h.toast_size_pct,
        h.rows,
        h.avg_row_size,
        h.is_rollup
    FROM hist_tables_size h
        JOIN stat_collect_job j ON j.id = h.id_stat_collect_job AND j.instance = h.instance
        JOIN top_tables t ON t.instance = h.instance AND t.schema = h.schema AND t.name = h.name
),
with_growth AS (
    -- is_rollup is part of the partition key, not just a passthrough
    -- column: 0.4.3 made total_size mean "whole partition/inheritance
    -- subtree" instead of "this one relation", for any table that
    -- turns out to be a rollup root -- under the same (instance,
    -- schema, name), so the first rollup-scoped row would otherwise
    -- show a one-time jump that lag()/first_value() would read as
    -- real growth. Splitting the window by is_rollup makes that first
    -- row start a new series (prev/first values NULL) instead.
    SELECT
        history.*,
        lag(total_size) OVER w_seq             AS prev_total_size,
        lag(collect_date) OVER w_seq           AS prev_collect_date,
        first_value(total_size) OVER w_full    AS first_total_size,
        first_value(collect_date) OVER w_full  AS first_collect_date,
        last_value(total_size) OVER w_full     AS last_total_size,
        last_value(collect_date) OVER w_full   AS last_collect_date
    FROM history
    WINDOW
        w_seq AS (PARTITION BY instance, schema, name, is_rollup ORDER BY collect_date),
        w_full AS (PARTITION BY instance, schema, name, is_rollup ORDER BY collect_date
                   ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
)
SELECT
    collect_date,
    instance,
    tablespace,
    schema,
    name,
    type,
    persistence,
    owner,
    total_size,
    index_size,
    index_size_pct,
    heap_size,
    heap_size_pct,
    toast_size,
    toast_size_pct,
    rows,
    avg_row_size,
    (total_size - prev_total_size)
        / nullif(collect_date - prev_collect_date, 0) * 30 AS month_growth_bytes,
    round(
        (total_size - prev_total_size) * 100.0 / nullif(prev_total_size, 0)
            / nullif(collect_date - prev_collect_date, 0) * 30
    , 2) AS month_growth_pct,
    (last_total_size - first_total_size)
        / nullif(last_collect_date - first_collect_date, 0) * 365 AS year_growth_bytes,
    round(
        (last_total_size - first_total_size) * 100.0 / nullif(first_total_size, 0)
            / nullif(last_collect_date - first_collect_date, 0) * 365
    , 2) AS year_growth_pct,
    is_rollup
FROM with_growth
ORDER BY collect_date DESC, instance, total_size DESC;

CREATE OR REPLACE VIEW rpt_tables_size_history AS
SELECT
    collect_date,
    instance,
    tablespace,
    schema,
    name,
    type,
    persistence,
    owner,
    lpad(pg_size_pretty(round(total_size)::bigint), 7) AS total_size,
    lpad(pg_size_pretty(round(index_size)::bigint), 7) AS index_size,
    index_size_pct,
    lpad(pg_size_pretty(round(heap_size)::bigint), 7) AS heap_size,
    heap_size_pct,
    lpad(pg_size_pretty(round(toast_size)::bigint), 7) AS toast_size,
    toast_size_pct,
    lpad(to_char(rows, 'FM999G999G999G999G999'), 15) AS rows,
    avg_row_size,
    lpad(pg_size_pretty(round(month_growth_bytes)::bigint), 8) AS month_growth_bytes,
    month_growth_pct,
    lpad(pg_size_pretty(round(year_growth_bytes)::bigint), 8) AS year_growth_bytes,
    year_growth_pct,
    is_rollup
FROM rpt_tables_size_history_raw;

COMMIT;
