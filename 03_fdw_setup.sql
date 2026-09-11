-- Run on the central stats database as admin.
--   psql <connection target> -f 03_fdw_setup.sql
--
-- Defines setup_instance_fdw(instance, password): creates that
-- instance's FOREIGN SERVER + USER MAPPING and its 7 foreign tables,
-- reading host/port/database_name/remote_user from instance_config (so
-- that table is the only place holding connection details). Doesn't
-- populate instance_config or call the procedure itself -- see
-- deploy.py / config.yaml, or `./deploy.py --update` for one instance
-- added later.

CREATE OR REPLACE PROCEDURE stats_collect.setup_instance_fdw(
    p_instance stats_collect.instance_name,
    p_password text
)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_server      name;
    v_host        text;
    v_port        int;
    v_dbname      text;
    v_remote_user text;
    v_view        text;
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

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            datid oid, datname name, numbackends integer, xact_commit bigint,
            xact_rollback bigint, blks_read bigint, blks_hit bigint,
            tup_returned bigint, tup_fetched bigint, tup_inserted bigint,
            tup_updated bigint, tup_deleted bigint, conflicts bigint,
            temp_files bigint, temp_bytes bigint, deadlocks bigint,
            checksum_failures bigint, checksum_last_failure timestamptz,
            blk_read_time double precision, blk_write_time double precision,
            session_time double precision, active_time double precision,
            idle_in_transaction_time double precision, sessions bigint,
            sessions_abandoned bigint, sessions_fatal bigint,
            sessions_killed bigint, stats_reset timestamptz
        ) SERVER %I OPTIONS (schema_name 'pg_catalog', table_name 'pg_stat_database')
    $f$, 'pg_stat_database_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            datid oid, datname name, confl_tablespace bigint, confl_lock bigint,
            confl_snapshot bigint, confl_bufferpin bigint, confl_deadlock bigint,
            confl_active_logicalslot bigint
        ) SERVER %I OPTIONS (schema_name 'pg_catalog', table_name 'pg_stat_database_conflicts')
    $f$, 'pg_stat_database_conflicts_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            relid oid, schemaname name, relname name, heap_blks_read bigint,
            heap_blks_hit bigint, idx_blks_read bigint, idx_blks_hit bigint,
            toast_blks_read bigint, toast_blks_hit bigint, tidx_blks_read bigint,
            tidx_blks_hit bigint
        ) SERVER %I OPTIONS (schema_name 'pg_catalog', table_name 'pg_statio_all_tables')
    $f$, 'pg_statio_all_tables_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            relid oid, indexrelid oid, schemaname name, relname name,
            indexrelname name, idx_blks_read bigint, idx_blks_hit bigint
        ) SERVER %I OPTIONS (schema_name 'pg_catalog', table_name 'pg_statio_all_indexes')
    $f$, 'pg_statio_all_indexes_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            relid oid, schemaname name, relname name, seq_scan bigint,
            last_seq_scan timestamptz, seq_tup_read bigint, idx_scan bigint,
            last_idx_scan timestamptz, idx_tup_fetch bigint, n_tup_ins bigint,
            n_tup_upd bigint, n_tup_del bigint, n_tup_hot_upd bigint,
            n_tup_newpage_upd bigint, n_live_tup bigint, n_dead_tup bigint,
            n_mod_since_analyze bigint, n_ins_since_vacuum bigint,
            last_vacuum timestamptz, last_autovacuum timestamptz,
            last_analyze timestamptz, last_autoanalyze timestamptz,
            vacuum_count bigint, autovacuum_count bigint, analyze_count bigint,
            autoanalyze_count bigint
        ) SERVER %I OPTIONS (schema_name 'pg_catalog', table_name 'pg_stat_all_tables')
    $f$, 'pg_stat_all_tables_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            userid oid, dbid oid, toplevel boolean, queryid bigint, query text,
            plans bigint, total_plan_time double precision, min_plan_time double precision,
            max_plan_time double precision, mean_plan_time double precision,
            stddev_plan_time double precision, calls bigint, total_exec_time double precision,
            min_exec_time double precision, max_exec_time double precision,
            mean_exec_time double precision, stddev_exec_time double precision, rows bigint,
            shared_blks_hit bigint, shared_blks_read bigint, shared_blks_dirtied bigint,
            shared_blks_written bigint, local_blks_hit bigint, local_blks_read bigint,
            local_blks_dirtied bigint, local_blks_written bigint, temp_blks_read bigint,
            temp_blks_written bigint, shared_blk_read_time double precision,
            shared_blk_write_time double precision, local_blk_read_time double precision,
            local_blk_write_time double precision, temp_blk_read_time double precision,
            temp_blk_write_time double precision, wal_records bigint, wal_fpi bigint,
            wal_bytes numeric, jit_functions bigint, jit_generation_time double precision,
            jit_inlining_count bigint, jit_inlining_time double precision,
            jit_optimization_count bigint, jit_optimization_time double precision,
            jit_emission_count bigint, jit_emission_time double precision,
            jit_deform_count bigint, jit_deform_time double precision,
            stats_since timestamptz, minmax_stats_since timestamptz
        ) SERVER %I OPTIONS (schema_name 'public', table_name 'pg_stat_statements')
    $f$, 'pg_stat_statements_' || p_instance, v_server);

    EXECUTE format($f$
        CREATE FOREIGN TABLE stats_collect.%I (
            dealloc bigint, stats_reset timestamptz
        ) SERVER %I OPTIONS (schema_name 'public', table_name 'pg_stat_statements_info')
    $f$, 'pg_stat_statements_info_' || p_instance, v_server);

    FOREACH v_view IN ARRAY ARRAY[
        'pg_stat_database', 'pg_stat_database_conflicts', 'pg_statio_all_tables',
        'pg_statio_all_indexes', 'pg_stat_all_tables', 'pg_stat_statements',
        'pg_stat_statements_info'
    ] LOOP
        EXECUTE format('ALTER FOREIGN TABLE stats_collect.%I OWNER TO stats_collect_owner', v_view || '_' || p_instance);
    END LOOP;
END;
$proc$;

ALTER PROCEDURE stats_collect.setup_instance_fdw(stats_collect.instance_name, text) OWNER TO stats_collect_owner;
