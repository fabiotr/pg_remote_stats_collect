-- Run on the central stats database as admin.
--   psql <connection target> -f 03_fdw_setup.sql
--
-- Defines setup_instance_fdw(instance, password): creates that
-- instance's FOREIGN SERVER + USER MAPPING, probes its actual
-- server_version_num and pg_stat_statements extversion via dblink, and
-- creates its 7 foreign tables with only the columns that version tier
-- actually has (see the hist_pg_stat_* comment in 02_setup.sql).
-- Minimum supported: PostgreSQL 10 / pg_stat_statements 1.6 -- refuses
-- an older instance instead of building it incomplete. pg_stat_statements_info
-- doesn't exist before extension 1.9 (PG14), so its foreign table is
-- skipped for an older instance.
--
-- Reads host/port/database_name/remote_user from instance_config (the
-- only place holding connection details). Doesn't populate
-- instance_config or call the procedure itself -- see deploy.py /
-- config.yaml, or `./deploy.py --update` for one instance added later.

CREATE OR REPLACE PROCEDURE stats_collect.setup_instance_fdw(
    p_instance stats_collect.instance_name,
    p_password text
)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_server        name;
    v_host          text;
    v_port          int;
    v_dbname        text;
    v_remote_user   text;
    v_view          text;
    v_pg_version    int;
    v_pgss_major    int;
    v_pgss_minor    int;
    v_has_stmt_info boolean;
    v_cols          text;
    v_conninfo      text;
BEGIN
    SELECT fdw_server, host, port, database_name, remote_user
        INTO v_server, v_host, v_port, v_dbname, v_remote_user
        FROM stats_collect.instance_config
        WHERE instance = p_instance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'instance % has no row in stats_collect.instance_config', p_instance;
    END IF;

    EXECUTE format(
        'CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L)',
        v_server, v_host, v_port::text, v_dbname);
    EXECUTE format('ALTER SERVER %I OWNER TO stats_collect_owner', v_server);

    -- FOR stats_collect_owner (not CURRENT_USER): pg_cron runs
    -- collect_stats() as that role, and dblink_connect() resolves the
    -- mapping by CURRENT_USER at call time.
    EXECUTE format(
        'CREATE USER MAPPING FOR stats_collect_owner SERVER %I OPTIONS (user %L, password %L)',
        v_server, v_remote_user, p_password);

    -- Raw connection string, not the SERVER name -- admin (who calls
    -- this procedure) has no USER MAPPING; only stats_collect_owner
    -- does, created just above.
    v_conninfo := format('host=%s port=%s dbname=%s user=%s password=%s', v_host, v_port, v_dbname, v_remote_user, p_password);

    SELECT t.v INTO v_pg_version
    FROM stats_collect.dblink(v_conninfo, $sql$SELECT current_setting('server_version_num')::int$sql$) AS t(v int);

    SELECT split_part(t.v, '.', 1)::int, split_part(t.v, '.', 2)::int
        INTO v_pgss_major, v_pgss_minor
    FROM stats_collect.dblink(v_conninfo, $sql$SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements'$sql$) AS t(v text);

    IF v_pg_version < 100000 THEN
        RAISE EXCEPTION 'instance % is running PostgreSQL %, older than the minimum supported (10)', p_instance, v_pg_version;
    END IF;
    IF v_pgss_major IS NULL THEN
        RAISE EXCEPTION 'instance % has no pg_stat_statements extension installed -- required, see README', p_instance;
    END IF;
    IF (v_pgss_major, v_pgss_minor) < (1, 6) THEN
        RAISE EXCEPTION 'instance % has pg_stat_statements %.%, older than the minimum supported (1.6, bundled with PostgreSQL 10)', p_instance, v_pgss_major, v_pgss_minor;
    END IF;

    -- ---- pg_stat_database ----
    v_cols := 'datid oid, datname name, numbackends integer, xact_commit bigint, '
        || 'xact_rollback bigint, blks_read bigint, blks_hit bigint, tup_returned bigint, '
        || 'tup_fetched bigint, tup_inserted bigint, tup_updated bigint, tup_deleted bigint, '
        || 'conflicts bigint, temp_files bigint, temp_bytes bigint, deadlocks bigint, '
        || 'blk_read_time double precision, blk_write_time double precision, stats_reset timestamptz';
    IF v_pg_version >= 120000 THEN
        v_cols := v_cols || ', checksum_failures bigint, checksum_last_failure timestamptz';
    END IF;
    IF v_pg_version >= 140000 THEN
        v_cols := v_cols || ', session_time double precision, active_time double precision, '
            || 'idle_in_transaction_time double precision, sessions bigint, sessions_abandoned bigint, '
            || 'sessions_fatal bigint, sessions_killed bigint';
    END IF;
    IF v_pg_version >= 180000 THEN
        v_cols := v_cols || ', parallel_workers_to_launch bigint, parallel_workers_launched bigint';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_stat_database_' || p_instance, v_cols, v_server, 'pg_catalog', 'pg_stat_database');

    -- ---- pg_stat_database_conflicts ----
    v_cols := 'datid oid, datname name, confl_tablespace bigint, confl_lock bigint, '
        || 'confl_snapshot bigint, confl_bufferpin bigint, confl_deadlock bigint';
    IF v_pg_version >= 160000 THEN
        v_cols := v_cols || ', confl_active_logicalslot bigint';
    END IF;
    IF v_pg_version >= 190000 THEN
        v_cols := v_cols || ', stats_reset timestamptz';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_stat_database_conflicts_' || p_instance, v_cols, v_server, 'pg_catalog', 'pg_stat_database_conflicts');

    -- ---- pg_statio_all_tables ----
    v_cols := 'relid oid, schemaname name, relname name, heap_blks_read bigint, '
        || 'heap_blks_hit bigint, idx_blks_read bigint, idx_blks_hit bigint, toast_blks_read bigint, '
        || 'toast_blks_hit bigint, tidx_blks_read bigint, tidx_blks_hit bigint';
    IF v_pg_version >= 190000 THEN
        v_cols := v_cols || ', stats_reset timestamptz';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_statio_all_tables_' || p_instance, v_cols, v_server, 'pg_catalog', 'pg_statio_all_tables');

    -- ---- pg_statio_all_indexes ----
    v_cols := 'relid oid, indexrelid oid, schemaname name, relname name, indexrelname name, '
        || 'idx_blks_read bigint, idx_blks_hit bigint';
    IF v_pg_version >= 190000 THEN
        v_cols := v_cols || ', stats_reset timestamptz';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_statio_all_indexes_' || p_instance, v_cols, v_server, 'pg_catalog', 'pg_statio_all_indexes');

    -- ---- pg_stat_all_tables ----
    v_cols := 'relid oid, schemaname name, relname name, seq_scan bigint, seq_tup_read bigint, '
        || 'idx_scan bigint, idx_tup_fetch bigint, n_tup_ins bigint, n_tup_upd bigint, n_tup_del bigint, '
        || 'n_tup_hot_upd bigint, n_live_tup bigint, n_dead_tup bigint, n_mod_since_analyze bigint, '
        || 'last_vacuum timestamptz, last_autovacuum timestamptz, last_analyze timestamptz, '
        || 'last_autoanalyze timestamptz, vacuum_count bigint, autovacuum_count bigint, '
        || 'analyze_count bigint, autoanalyze_count bigint';
    IF v_pg_version >= 130000 THEN
        v_cols := v_cols || ', n_ins_since_vacuum bigint';
    END IF;
    IF v_pg_version >= 160000 THEN
        v_cols := v_cols || ', last_seq_scan timestamptz, last_idx_scan timestamptz, n_tup_newpage_upd bigint';
    END IF;
    IF v_pg_version >= 180000 THEN
        v_cols := v_cols || ', total_vacuum_time double precision, total_autovacuum_time double precision, '
            || 'total_analyze_time double precision, total_autoanalyze_time double precision';
    END IF;
    IF v_pg_version >= 190000 THEN
        v_cols := v_cols || ', stats_reset timestamptz';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_stat_all_tables_' || p_instance, v_cols, v_server, 'pg_catalog', 'pg_stat_all_tables');

    -- ---- pg_stat_statements (versioned by extension, not server version) ----
    v_cols := 'userid oid, dbid oid, queryid bigint, query text, calls bigint, rows bigint, '
        || 'shared_blks_hit bigint, shared_blks_read bigint, shared_blks_dirtied bigint, '
        || 'shared_blks_written bigint, local_blks_hit bigint, local_blks_read bigint, '
        || 'local_blks_dirtied bigint, local_blks_written bigint, temp_blks_read bigint, '
        || 'temp_blks_written bigint';
    IF (v_pgss_major, v_pgss_minor) < (1, 11) THEN
        -- split into shared/local_blk_* below as of 1.11
        v_cols := v_cols || ', blk_read_time double precision, blk_write_time double precision';
    END IF;
    IF (v_pgss_major, v_pgss_minor) < (1, 8) THEN
        v_cols := v_cols || ', total_time double precision, min_time double precision, '
            || 'max_time double precision, mean_time double precision, stddev_time double precision';
    ELSE
        v_cols := v_cols || ', plans bigint, total_plan_time double precision, min_plan_time double precision, '
            || 'max_plan_time double precision, mean_plan_time double precision, stddev_plan_time double precision, '
            || 'total_exec_time double precision, min_exec_time double precision, max_exec_time double precision, '
            || 'mean_exec_time double precision, stddev_exec_time double precision, '
            || 'wal_records bigint, wal_fpi bigint, wal_bytes numeric';
    END IF;
    IF (v_pgss_major, v_pgss_minor) >= (1, 9) THEN
        v_cols := v_cols || ', toplevel boolean';
    END IF;
    IF (v_pgss_major, v_pgss_minor) >= (1, 10) THEN
        v_cols := v_cols || ', temp_blk_read_time double precision, temp_blk_write_time double precision, '
            || 'jit_functions bigint, jit_generation_time double precision, jit_inlining_count bigint, '
            || 'jit_inlining_time double precision, jit_optimization_count bigint, jit_optimization_time double precision, '
            || 'jit_emission_count bigint, jit_emission_time double precision';
    END IF;
    IF (v_pgss_major, v_pgss_minor) >= (1, 11) THEN
        v_cols := v_cols || ', shared_blk_read_time double precision, shared_blk_write_time double precision, '
            || 'local_blk_read_time double precision, local_blk_write_time double precision, '
            || 'jit_deform_count bigint, jit_deform_time double precision, '
            || 'stats_since timestamptz, minmax_stats_since timestamptz';
    END IF;
    IF (v_pgss_major, v_pgss_minor) >= (1, 12) THEN
        v_cols := v_cols || ', wal_buffers_full bigint, parallel_workers_to_launch bigint, parallel_workers_launched bigint';
    END IF;
    IF (v_pgss_major, v_pgss_minor) >= (1, 13) THEN
        v_cols := v_cols || ', generic_plan_calls bigint, custom_plan_calls bigint';
    END IF;
    EXECUTE format(
        'CREATE FOREIGN TABLE stats_collect.%I (%s) SERVER %I OPTIONS (schema_name %L, table_name %L)',
        'pg_stat_statements_' || p_instance, v_cols, v_server, 'public', 'pg_stat_statements');

    -- ---- pg_stat_statements_info: doesn't exist before extension 1.9 ----
    v_has_stmt_info := (v_pgss_major, v_pgss_minor) >= (1, 9);
    IF v_has_stmt_info THEN
        EXECUTE format(
            'CREATE FOREIGN TABLE stats_collect.%I (dealloc bigint, stats_reset timestamptz) SERVER %I OPTIONS (schema_name %L, table_name %L)',
            'pg_stat_statements_info_' || p_instance, v_server, 'public', 'pg_stat_statements_info');
    END IF;

    FOREACH v_view IN ARRAY ARRAY[
        'pg_stat_database', 'pg_stat_database_conflicts', 'pg_statio_all_tables',
        'pg_statio_all_indexes', 'pg_stat_all_tables', 'pg_stat_statements'
    ] LOOP
        EXECUTE format('ALTER FOREIGN TABLE stats_collect.%I OWNER TO stats_collect_owner', v_view || '_' || p_instance);
    END LOOP;
    IF v_has_stmt_info THEN
        EXECUTE format('ALTER FOREIGN TABLE stats_collect.%I OWNER TO stats_collect_owner', 'pg_stat_statements_info_' || p_instance);
    END IF;
END;
$proc$;

ALTER PROCEDURE stats_collect.setup_instance_fdw(stats_collect.instance_name, text) OWNER TO stats_collect_owner;
