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
-- =====================================================================

BEGIN;

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
            WITH RECURSIVE partition_tree AS (
                -- Anchor: every non-temp, visible table/materialized
                -- view/partitioned-or-inherited parent that is not
                -- itself a partition/child of something else.
                SELECT c.oid, c.oid AS root_oid
                FROM pg_class c
                    LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r','m','p')
                    AND c.relpersistence != 'temporary'
                    AND n.nspname <> 'information_schema'
                    AND n.nspname !~ '^pg_toast'
                    AND pg_table_is_visible(c.oid)
                    AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
                UNION ALL
                -- Walk down to every partition/child, tagging each with
                -- its top-level ancestor (root_oid), however many levels
                -- deep -- a partitioned table is sized as one table, not
                -- one row per partition.
                SELECT i.inhrelid, pt.root_oid
                FROM pg_inherits i
                    JOIN partition_tree pt ON i.inhparent = pt.oid
            ),
            leaves AS (
                -- Only relkind 'r'/'m' leaves have storage of their own
                -- -- a partitioned/inheritance parent (relkind 'p') is a
                -- catalog-only placeholder with no physical size, so it
                -- never contributes its own row here, only its leaves'.
                SELECT pt.root_oid, leaf.oid AS leaf_oid, leaf.reltoastrelid, leaf.reltuples
                FROM partition_tree pt
                    JOIN pg_class leaf ON leaf.oid = pt.oid
                WHERE leaf.relkind IN ('r','m')
            )
            SELECT
                coalesce(t.spcname, nullif(current_setting('default_tablespace'),''), 'pg_default') AS tablespace,
                n.nspname AS schema,
                c.relname AS name,
                CASE c.relkind WHEN 'r' THEN 'table' WHEN 'm' THEN 'materialized view' WHEN 'p' THEN 'partitioned table' END AS type,
                CASE c.relpersistence WHEN 'p' THEN 'permanent' WHEN 'u' THEN 'unlogged' END AS persistence,
                pg_get_userbyid(c.relowner) AS owner,
                sum(pg_total_relation_size(l.leaf_oid)) AS total_size,
                sum(pg_indexes_size(l.leaf_oid)) AS index_size,
                round(100 * sum(pg_indexes_size(l.leaf_oid)) / nullif(sum(pg_total_relation_size(l.leaf_oid)),0), 2) AS index_size_pct,
                sum(pg_relation_size(l.leaf_oid,'main')) AS heap_size,
                round(100 * sum(pg_relation_size(l.leaf_oid,'main')) / nullif(sum(pg_total_relation_size(l.leaf_oid)),0), 2) AS heap_size_pct,
                sum(CASE WHEN l.reltoastrelid <> 0 THEN pg_table_size(l.reltoastrelid) ELSE 0 END) AS toast_size,
                round(100 * sum(CASE WHEN l.reltoastrelid <> 0 THEN pg_table_size(l.reltoastrelid) ELSE 0 END)
                    / nullif(sum(pg_total_relation_size(l.leaf_oid)),0), 2) AS toast_size_pct,
                sum(l.reltuples) AS rows,
                trunc(sum(pg_table_size(l.leaf_oid)) / nullif(sum(l.reltuples),0))::numeric AS avg_row_size
            FROM leaves l
                JOIN pg_class c ON c.oid = l.root_oid
                LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
                LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            GROUP BY c.oid, t.spcname, n.nspname, c.relname, c.relkind, c.relpersistence, c.relowner
            ORDER BY sum(pg_total_relation_size(l.leaf_oid)) DESC
            LIMIT 20
        $sql_tblsize$) AS s(
            tablespace text, schema name, name name, type text, persistence text,
            owner name, total_size bigint, index_size bigint, index_size_pct numeric,
            heap_size bigint, heap_size_pct numeric, toast_size bigint,
            toast_size_pct numeric, rows real, avg_row_size numeric
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

COMMIT;
