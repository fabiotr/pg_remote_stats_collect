-- Run on the central stats database as admin.
-- Requires -v instance_name_values="'<a>','<b>',..." (deploy.py computes
-- this from config.yaml automatically):
--   psql <connection target> -f 02_setup.sql -v instance_name_values="'main','main_replica1'"

CREATE ROLE stats_collect_owner NOLOGIN;
CREATE SCHEMA stats_collect AUTHORIZATION stats_collect_owner;

-- Backs the foreign servers/tables 03_fdw_setup.sql creates.
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Only used for the 4 "raw" queries in 04_collect_procedure.sql: they
-- call VOLATILE size functions that postgres_fdw can't push down to the
-- remote side, so those run through dblink instead, which sends the
-- whole query text over to execute remotely.
CREATE EXTENSION IF NOT EXISTS dblink SCHEMA stats_collect;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA stats_collect TO stats_collect_owner;

SET search_path = stats_collect;

-- instance_name_values is psql-substituted above the DO block (not
-- inside it -- psql doesn't substitute inside dollar-quoted text) via a
-- GUC, so the DO block can read it back with current_setting().
SET stats_collect_deploy.instance_name_values = :'instance_name_values';

DO $$
BEGIN
    EXECUTE format('CREATE TYPE instance_name AS ENUM (%s)',
        current_setting('stats_collect_deploy.instance_name_values'));
EXCEPTION WHEN duplicate_object THEN
    NULL; -- already exists, e.g. re-run after adding a value by hand
END $$;

-- Purely descriptive -- collect_stats() doesn't branch on it.
CREATE TYPE instance_type AS ENUM ('Writer', 'Reader', 'Other');

CREATE TYPE job_status AS ENUM ('running', 'succeeded', 'failed');

-- One row per project release -- see releases.yaml at the repo root,
-- the single source of truth this table mirrors. Written only by
-- deploy.py: a fresh deploy stamps every release in releases.yaml at
-- once (nothing to migrate, only to record); `./deploy.py --migrate`
-- on an already-deployed environment runs each pending release's
-- migration (migrations/NNNN_*.sql) in order, then records it.
CREATE TABLE schema_releases (
    version     text primary key,
    deployed_at timestamptz not null default clock_timestamp(),
    description text not null
);

-- One row per (collection run, instance) -- collect_stats() gives
-- every instance it collects its own row under the same job id, so
-- status/timing/errors are tracked independently per instance instead
-- of once for the whole run. version is that instance's
-- server_version_num, fetched via dblink at collection time.
CREATE TABLE stat_collect_job (
    id            serial,
    instance      instance_name not null,
    version       numeric,
    collect_start timestamp,
    collect_end   timestamp,
    status        job_status,
    errors        text[],
    PRIMARY KEY (id, instance)
);

-- cluster: the instance's own name if it's a writer, or its writer's
-- name if it's a reader -- a writer always has cluster = instance.
-- sys_prefix: groups instances expected to share the same objects,
-- independent of cluster/region.
CREATE TABLE instance_config (
    instance      instance_name primary key,
    fdw_server    name not null,
    host          text not null,
    port          int not null default 5432,
    database_name text not null,
    remote_user   text not null,
    cluster       instance_name not null,
    instance_type instance_type not null,
    enabled       boolean not null default true,
    sys_prefix    text not null,
    notes         text
);

-- 1) 7 tables mirroring the source stats views, plus id_stat_collect_job
--    + instance. Each is the union of every column its view has ever
--    had (PostgreSQL 10-19; pg_stat_statements/_info by their own
--    extension version, 1.6-1.13), all nullable -- setup_instance_fdw()
--    gives each instance's foreign tables only the columns its version
--    actually has, and collect_stats() matches columns by name,
--    NULLing the rest (see copy_matching_columns() in
--    04_collect_procedure.sql).
--
--    A column that changed meaning without changing name (e.g.
--    n_tup_hot_upd narrowed in PG16) isn't split out here -- cross-check
--    stat_collect_job.version for which semantics applied.
CREATE TABLE hist_pg_stat_database (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    datid                oid,
    datname              name,
    numbackends          integer,
    xact_commit          bigint,
    xact_rollback        bigint,
    blks_read            bigint,
    blks_hit             bigint,
    tup_returned         bigint,
    tup_fetched          bigint,
    tup_inserted         bigint,
    tup_updated          bigint,
    tup_deleted          bigint,
    conflicts            bigint,
    temp_files           bigint,
    temp_bytes           bigint,
    deadlocks            bigint,
    checksum_failures    bigint,
    checksum_last_failure timestamptz,
    blk_read_time        double precision,
    blk_write_time       double precision,
    session_time         double precision,
    active_time          double precision,
    idle_in_transaction_time double precision,
    sessions             bigint,
    sessions_abandoned   bigint,
    sessions_fatal       bigint,
    sessions_killed      bigint,
    parallel_workers_to_launch bigint,
    parallel_workers_launched  bigint,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_stat_database (instance, id_stat_collect_job);

CREATE TABLE hist_pg_stat_database_conflicts (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    datid                oid,
    datname              name,
    confl_tablespace     bigint,
    confl_lock           bigint,
    confl_snapshot       bigint,
    confl_bufferpin      bigint,
    confl_deadlock       bigint,
    confl_active_logicalslot bigint,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_stat_database_conflicts (instance, id_stat_collect_job);

CREATE TABLE hist_pg_statio_all_tables (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    relid                oid,
    schemaname           name,
    relname              name,
    heap_blks_read       bigint,
    heap_blks_hit        bigint,
    idx_blks_read        bigint,
    idx_blks_hit         bigint,
    toast_blks_read      bigint,
    toast_blks_hit       bigint,
    tidx_blks_read       bigint,
    tidx_blks_hit        bigint,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_statio_all_tables (instance, id_stat_collect_job);

CREATE TABLE hist_pg_statio_all_indexes (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    relid                oid,
    indexrelid           oid,
    schemaname           name,
    relname              name,
    indexrelname         name,
    idx_blks_read        bigint,
    idx_blks_hit         bigint,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_statio_all_indexes (instance, id_stat_collect_job);

CREATE TABLE hist_pg_stat_all_tables (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    relid                oid,
    schemaname           name,
    relname              name,
    seq_scan             bigint,
    last_seq_scan        timestamptz,
    seq_tup_read         bigint,
    idx_scan             bigint,
    last_idx_scan        timestamptz,
    idx_tup_fetch        bigint,
    n_tup_ins            bigint,
    n_tup_upd            bigint,
    n_tup_del            bigint,
    n_tup_hot_upd        bigint,
    n_tup_newpage_upd    bigint,
    n_live_tup           bigint,
    n_dead_tup           bigint,
    n_mod_since_analyze  bigint,
    n_ins_since_vacuum   bigint,
    last_vacuum          timestamptz,
    last_autovacuum      timestamptz,
    last_analyze         timestamptz,
    last_autoanalyze     timestamptz,
    vacuum_count         bigint,
    autovacuum_count     bigint,
    analyze_count        bigint,
    autoanalyze_count    bigint,
    total_vacuum_time      double precision,
    total_autovacuum_time  double precision,
    total_analyze_time     double precision,
    total_autoanalyze_time double precision,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_stat_all_tables (instance, id_stat_collect_job);

CREATE TABLE hist_pg_stat_statements (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    userid               oid,
    dbid                 oid,
    toplevel             boolean,
    queryid              bigint,
    query                text,
    plans                bigint,
    -- pre-1.8 (PG10-12) only; split into total_plan/exec_time below
    total_time           double precision,
    min_time             double precision,
    max_time             double precision,
    mean_time            double precision,
    stddev_time          double precision,
    total_plan_time      double precision,
    min_plan_time        double precision,
    max_plan_time        double precision,
    mean_plan_time       double precision,
    stddev_plan_time     double precision,
    calls                bigint,
    total_exec_time      double precision,
    min_exec_time        double precision,
    max_exec_time        double precision,
    mean_exec_time       double precision,
    stddev_exec_time     double precision,
    rows                 bigint,
    shared_blks_hit      bigint,
    shared_blks_read     bigint,
    shared_blks_dirtied  bigint,
    shared_blks_written  bigint,
    local_blks_hit       bigint,
    local_blks_read      bigint,
    local_blks_dirtied   bigint,
    local_blks_written   bigint,
    temp_blks_read       bigint,
    temp_blks_written    bigint,
    -- pre-1.11 (through PG16) only; split into shared/local_blk_* below
    blk_read_time        double precision,
    blk_write_time       double precision,
    shared_blk_read_time double precision,
    shared_blk_write_time double precision,
    local_blk_read_time  double precision,
    local_blk_write_time double precision,
    temp_blk_read_time   double precision,
    temp_blk_write_time  double precision,
    wal_records          bigint,
    wal_fpi              bigint,
    wal_bytes            numeric,
    jit_functions        bigint,
    jit_generation_time  double precision,
    jit_inlining_count   bigint,
    jit_inlining_time    double precision,
    jit_optimization_count bigint,
    jit_optimization_time double precision,
    jit_emission_count   bigint,
    jit_emission_time    double precision,
    jit_deform_count     bigint,
    jit_deform_time      double precision,
    stats_since          timestamptz,
    minmax_stats_since   timestamptz,
    wal_buffers_full     bigint,
    parallel_workers_to_launch bigint,
    parallel_workers_launched  bigint,
    generic_plan_calls   bigint,
    custom_plan_calls    bigint,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_stat_statements (instance, id_stat_collect_job);
CREATE INDEX ON hist_pg_stat_statements (queryid);

CREATE TABLE hist_pg_stat_statements_info (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    dealloc              bigint,
    stats_reset          timestamptz,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_pg_stat_statements_info (instance, id_stat_collect_job);

-- 2) "Raw" (unformatted) versions of four queries from this repo's
--    sql/ directory -- same logic/filters/LIMIT, numeric instead of
--    pretty-printed so results are comparable across runs.

-- schemas_94up.sql
CREATE TABLE hist_schemas (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    nspname              name,
    size                 bigint,
    size_pct             numeric,
    tables               bigint,
    indexes              bigint,
    p_tables             bigint,
    p_indexes            bigint,
    m_views              bigint,
    toast                bigint,
    sequences            bigint,
    views                bigint,
    types                bigint,
    foreign_tables       bigint,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_schemas (instance, id_stat_collect_job);

-- object_size_90up.sql (top 20 largest objects)
CREATE TABLE hist_object_size (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    tablespace           text,
    schema               name,
    name                 name,
    type                 text,
    owner                name,
    size                 bigint,
    rows                 real,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_object_size (instance, id_stat_collect_job);

-- tables_size_95up.sql (top 10 largest tables)
CREATE TABLE hist_tables_size (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    tablespace           text,
    schema               name,
    name                 name,
    type                 text,
    persistence          text,
    owner                name,
    total_size           bigint,
    index_size           bigint,
    index_size_pct       numeric,
    heap_size            bigint,
    heap_size_pct        numeric,
    toast_size           bigint,
    toast_size_pct       numeric,
    rows                 real,
    avg_row_size         numeric,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_tables_size (instance, id_stat_collect_job);

-- index_poor_84up.sql (top 20 problematic indexes)
CREATE TABLE hist_index_poor (
    id_stat_collect_job bigint not null,
    instance             instance_name not null,
    reason               text,
    schemaname           name,
    tablename            name,
    indexname            name,
    idx_scan             bigint,
    all_scans            bigint,
    index_scan_pct       numeric,
    writes               bigint,
    scans_per_write      numeric,
    index_size           bigint,
    table_size           bigint,
    idx_is_btree         boolean,
    grp                  int,
    FOREIGN KEY (id_stat_collect_job, instance) REFERENCES stat_collect_job (id, instance)
);
CREATE INDEX ON hist_index_poor (instance, id_stat_collect_job);

-- Transfer ownership of everything above -- needed (not just a GRANT)
-- since pg_cron runs collect_stats() as stats_collect_owner.
ALTER TYPE job_status OWNER TO stats_collect_owner;
ALTER TYPE instance_type OWNER TO stats_collect_owner;

DO $$
DECLARE
    v_tbl text;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY[
        'schema_releases', 'stat_collect_job', 'instance_config',
        'hist_pg_stat_database', 'hist_pg_stat_database_conflicts',
        'hist_pg_statio_all_tables', 'hist_pg_statio_all_indexes',
        'hist_pg_stat_all_tables', 'hist_pg_stat_statements', 'hist_pg_stat_statements_info',
        'hist_schemas', 'hist_object_size', 'hist_tables_size', 'hist_index_poor'
    ] LOOP
        EXECUTE format('ALTER TABLE stats_collect.%I OWNER TO stats_collect_owner', v_tbl);
    END LOOP;
END $$;

-- instance_config is the exception: admin keeps inserting into it
-- directly (deploy.py, or by hand), and setup_instance_fdw() -- running
-- as admin -- reads it back. CURRENT_USER so this works for whichever
-- admin role runs it.
GRANT SELECT, INSERT, UPDATE ON instance_config TO CURRENT_USER;
