-- Run on the central stats database as admin.
--   psql <connection target> -f 04_collect_procedure.sql
--
-- Monthly job: opens a stat_collect_job row, loops over enabled
-- instances copying the 7 stats views (foreign table) and running 4
-- raw queries (dblink), then closes the job as succeeded/failed. Each
-- instance is atomic -- one instance's failure doesn't affect others,
-- and COMMITs after each instance keep progress visible and durable if
-- the job is interrupted partway.
--
-- No SET clause (e.g. "SET search_path") on this procedure: Postgres
-- forbids COMMIT/ROLLBACK inside a procedure that has one. That's why
-- every reference below is schema-qualified.

CREATE OR REPLACE PROCEDURE stats_collect.collect_stats()
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_job_id    bigint;
    v_inst      record;
    v_errors    text[] := '{}';
    v_inst_err  text;
BEGIN
    INSERT INTO stats_collect.stat_collect_job (collect_start, status)
    VALUES (clock_timestamp(), 'running')
    RETURNING id INTO v_job_id;
    COMMIT;

    RAISE NOTICE '[collect_stats] job % started', v_job_id;

    FOR v_inst IN SELECT * FROM stats_collect.instance_config WHERE enabled ORDER BY instance LOOP
        v_inst_err := NULL;
        RAISE NOTICE '[collect_stats] % - starting', v_inst.instance;
        BEGIN

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_stat_database SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_stat_database_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_stat_database_conflicts SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_stat_database_conflicts_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_statio_all_tables SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_statio_all_tables_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_statio_all_indexes SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_statio_all_indexes_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_stat_all_tables SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_stat_all_tables_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_stat_statements SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_stat_statements_' || v_inst.instance);

        EXECUTE format(
            'INSERT INTO stats_collect.hist_pg_stat_statements_info SELECT %L::bigint, %L::stats_collect.instance_name, * FROM stats_collect.%I',
            v_job_id, v_inst.instance::text, 'pg_stat_statements_info_' || v_inst.instance);

        -- ---- raw queries via dblink ----

        INSERT INTO stats_collect.hist_schemas
        SELECT v_job_id, v_inst.instance, s.*
        FROM stats_collect.dblink(v_inst.fdw_server, $sql_schemas$
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

        INSERT INTO stats_collect.hist_object_size
        SELECT v_job_id, v_inst.instance, s.*
        FROM stats_collect.dblink(v_inst.fdw_server, $sql_objsize$
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

        INSERT INTO stats_collect.hist_tables_size
        SELECT v_job_id, v_inst.instance, s.*
        FROM stats_collect.dblink(v_inst.fdw_server, $sql_tblsize$
            SELECT
                coalesce(t.spcname, nullif(current_setting('default_tablespace'),''), 'pg_default') AS tablespace,
                n.nspname AS schema,
                c.relname AS name,
                CASE c.relkind WHEN 'r' THEN 'table' WHEN 'm' THEN 'materialized view' WHEN 'p' THEN 'partition table' END AS type,
                CASE c.relpersistence WHEN 'p' THEN 'permanent' WHEN 'u' THEN 'unlogged' END AS persistence,
                pg_get_userbyid(c.relowner) AS owner,
                pg_total_relation_size(c.oid) AS total_size,
                pg_indexes_size(c.oid) AS index_size,
                round(100 * pg_indexes_size(c.oid) / nullif(pg_total_relation_size(c.oid),0), 2) AS index_size_pct,
                pg_relation_size(c.oid,'main') AS heap_size,
                round(100 * pg_relation_size(c.oid,'main') / nullif(pg_total_relation_size(c.oid),0), 2) AS heap_size_pct,
                pg_table_size(c.reltoastrelid) AS toast_size,
                round(100 * pg_table_size(c.reltoastrelid) / nullif(pg_total_relation_size(c.oid),0), 2) AS toast_size_pct,
                c.reltuples AS rows,
                trunc(pg_table_size(c.oid) / nullif(c.reltuples,0))::numeric AS avg_row_size
            FROM pg_class c
                LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
                LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','m','')
                AND c.relpersistence != 'temporary'
                AND n.nspname <> 'information_schema'
                AND n.nspname !~ '^pg_toast'
                AND pg_table_is_visible(c.oid)
            ORDER BY pg_total_relation_size(c.oid) DESC
            LIMIT 10
        $sql_tblsize$) AS s(
            tablespace text, schema name, name name, type text, persistence text,
            owner name, total_size bigint, index_size bigint, index_size_pct numeric,
            heap_size bigint, heap_size_pct numeric, toast_size bigint,
            toast_size_pct numeric, rows real, avg_row_size numeric
        );

        INSERT INTO stats_collect.hist_index_poor
        SELECT v_job_id, v_inst.instance, s.*
        FROM stats_collect.dblink(v_inst.fdw_server, $sql_idxpoor$
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
            v_errors := v_errors || format('%s: %s', v_inst.instance, v_inst_err);
            UPDATE stats_collect.stat_collect_job SET errors = v_errors WHERE id = v_job_id;
        ELSE
            RAISE NOTICE '[collect_stats] % - done', v_inst.instance;
        END IF;

        COMMIT; -- outside the exception block above -- required
    END LOOP;

    UPDATE stats_collect.stat_collect_job
    SET collect_end = clock_timestamp(),
        status = CASE WHEN v_errors = '{}' THEN 'succeeded'::stats_collect.job_status ELSE 'failed'::stats_collect.job_status END
    WHERE id = v_job_id;
    COMMIT;

    RAISE NOTICE '[collect_stats] job % finished - % instance(s) with errors',
        v_job_id, coalesce(array_length(v_errors, 1), 0);
END;
$proc$;

ALTER PROCEDURE stats_collect.collect_stats() OWNER TO stats_collect_owner;

-- Manual test: CALL stats_collect.collect_stats();
