-- =====================================================================
-- Run on the central stats database as admin (no SET ROLE).
--
-- Requires -v app_database=<name> — the application database name on
-- the source instances (config.yaml's job.runs_in), used to filter
-- pg_stat_database rows down to that one database instead of every
-- database on the instance. deploy.py passes this automatically; for a
-- manual/standalone run:
--
--   psql <connection target> -v app_database=<app_db_name> -f 06_reports.sql
--
-- Reporting views: historical (trend across jobs) and synthetic
-- (latest-job snapshot per instance). Some historical views come in a
-- pair: a plain numeric "_raw" one for further processing (charts,
-- aggregation), and the same name without the suffix formatted for
-- direct reading, built on top of "_raw" so the two can't drift apart.
-- =====================================================================
SET search_path = stats_collect;

-- ---------------------------------------------------------------------
-- Job run history, per instance (each instance in a job gets its own
-- row, with its own status/timing -- see stat_collect_job in 02_setup.sql).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_job_history AS
SELECT id, instance, version, status, collect_start, collect_end,
       collect_end - collect_start AS duration, errors
FROM stat_collect_job
ORDER BY collect_start DESC, instance;

-- ---------------------------------------------------------------------
-- Historical: database size and commit/rollback rate per instance,
-- across jobs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_db_activity_history_raw AS
SELECT
    j.collect_start::date AS collect_date,
    d.instance,
    d.datname,
    d.numbackends,
    d.xact_commit,
    d.xact_rollback,
    round(100.0 * d.blks_hit / nullif(d.blks_hit + d.blks_read, 0), 2) AS cache_hit_pct,
    d.temp_files,
    d.temp_bytes,
    d.deadlocks,
    d.conflicts
FROM hist_pg_stat_database d
    JOIN stat_collect_job j ON j.id = d.id_stat_collect_job AND j.instance = d.instance
    JOIN instance_config ic ON ic.instance = d.instance
WHERE d.datname = ic.database_name
ORDER BY j.collect_start DESC, d.instance;

CREATE OR REPLACE VIEW rpt_db_activity_history AS
SELECT
    collect_date,
    instance,
    datname,
    lpad(to_char(numbackends, 'FM999G999G999G999G999'), 15) AS numbackends,
    lpad(to_char(xact_commit, 'FM999G999G999G999G999'), 15) AS xact_commit,
    lpad(to_char(xact_rollback, 'FM999G999G999G999G999'), 15) AS xact_rollback,
    cache_hit_pct,
    lpad(to_char(temp_files, 'FM999G999G999G999G999'), 15) AS temp_files,
    lpad(pg_size_pretty(round(temp_bytes)::bigint), 7) AS temp_bytes,
    lpad(to_char(deadlocks, 'FM999G999G999G999G999'), 15) AS deadlocks,
    lpad(to_char(conflicts, 'FM999G999G999G999G999'), 15) AS conflicts
FROM rpt_db_activity_history_raw;

-- ---------------------------------------------------------------------
-- Historical: schema size growth.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_schema_growth_history_raw AS
SELECT
    j.collect_start::date AS collect_date,
    h.instance,
    h.nspname,
    h.size,
    h.size_pct,
    h.tables
FROM hist_schemas h
    JOIN stat_collect_job j ON j.id = h.id_stat_collect_job AND j.instance = h.instance
ORDER BY j.collect_start DESC, h.size DESC;

CREATE OR REPLACE VIEW rpt_schema_growth_history AS
SELECT
    collect_date,
    instance,
    nspname,
    lpad(pg_size_pretty(round(size)::bigint), 7) AS size,
    size_pct,
    lpad(to_char(tables, 'FM999G999G999G999G999'), 15) AS tables
FROM rpt_schema_growth_history_raw;

-- ---------------------------------------------------------------------
-- Historical: growth trend of the 20 largest tables per instance
-- (replicas omitted -- they carry the same size as their writer), with
-- month-over-month growth (extrapolated to 30 days between collections)
-- and an estimated annual growth (extrapolated to 365 days between the
-- first and last collection).
-- ---------------------------------------------------------------------
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
        h.avg_row_size
    FROM hist_tables_size h
        JOIN stat_collect_job j ON j.id = h.id_stat_collect_job AND j.instance = h.instance
        JOIN top_tables t ON t.instance = h.instance AND t.schema = h.schema AND t.name = h.name
),
with_growth AS (
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
        w_seq AS (PARTITION BY instance, schema, name ORDER BY collect_date),
        w_full AS (PARTITION BY instance, schema, name ORDER BY collect_date
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
    , 2) AS year_growth_pct
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
    year_growth_pct
FROM rpt_tables_size_history_raw;

-- ---------------------------------------------------------------------
-- Historical: pg_stat_statements totals for the app database, per
-- instance, per collection — based on fabiotr/pg_scripts's
-- statements_cluster_total_17up.sql, normalized to a rate ("/day") the
-- same way: cumulative totals since the tracked stats_reset, divided
-- by days elapsed as of THAT collection's collect_start (not "now" —
-- these are historical snapshots, not a live query, so each row's rate
-- reflects the reset-to-collection window at the time it was collected,
-- not a period-over-period delta between consecutive collections).
-- hist_pg_stat_statements only carries dbid (no datname), so it's
-- matched against hist_pg_stat_database's datid, within the same
-- instance and collection, to filter down to instance_config's
-- database_name.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_stmt_totals_history_raw AS
WITH app_db_stmts AS (
    SELECT s.*
    FROM hist_pg_stat_statements s
        JOIN hist_pg_stat_database d
            ON d.instance = s.instance
                AND d.id_stat_collect_job = s.id_stat_collect_job
                AND d.datid = s.dbid
        JOIN instance_config ic ON ic.instance = s.instance
    WHERE d.datname = ic.database_name
),
totals AS (
    SELECT
        instance,
        id_stat_collect_job,
        sum(calls)               AS calls,
        sum(rows)                AS rows,
        sum(total_plan_time)     AS total_plan_time,
        sum(total_exec_time)     AS total_exec_time,
        sum(shared_blks_hit)     AS shared_blks_hit,
        sum(shared_blks_read)    AS shared_blks_read,
        sum(shared_blks_written) AS shared_blks_written
    FROM app_db_stmts
    GROUP BY instance, id_stat_collect_job
),
with_reset_days AS (
    SELECT
        t.*,
        j.collect_start::date AS collect_date,
        nullif(EXTRACT(EPOCH FROM (j.collect_start - i.stats_reset)) / 86400, 0) AS reset_days
    FROM totals t
        JOIN stat_collect_job j ON j.id = t.id_stat_collect_job AND j.instance = t.instance
        JOIN hist_pg_stat_statements_info i
            ON i.id_stat_collect_job = t.id_stat_collect_job AND i.instance = t.instance
)
SELECT
    collect_date,
    instance,
    calls / reset_days                               AS calls_per_day,
    rows / reset_days                                AS rows_per_day,
    total_plan_time / reset_days                      AS plan_time_per_day,
    total_exec_time / reset_days                      AS exec_time_per_day,
    (total_plan_time + total_exec_time) / reset_days  AS total_time_per_day,
    (shared_blks_hit     * current_setting('block_size')::integer) / reset_days AS shared_hit_bytes_per_day,
    (shared_blks_read    * current_setting('block_size')::integer) / reset_days AS shared_read_bytes_per_day,
    (shared_blks_written * current_setting('block_size')::integer) / reset_days AS shared_write_bytes_per_day
FROM with_reset_days
ORDER BY collect_date DESC, instance;

CREATE OR REPLACE VIEW rpt_stmt_totals_history AS
SELECT
    collect_date,
    instance,
    lpad(to_char(calls_per_day, 'FM999G999G999G999G999'), 15) AS calls_per_day,
    lpad(to_char(rows_per_day, 'FM999G999G999G999G999'), 15)  AS rows_per_day,
    to_char(plan_time_per_day * INTERVAL '1 millisecond', 'HH24:MI:SS') AS plan_time_per_day,
    to_char(exec_time_per_day * INTERVAL '1 millisecond', 'HH24:MI:SS') AS exec_time_per_day,
    to_char(total_time_per_day * INTERVAL '1 millisecond', 'HH24:MI:SS') AS total_time_per_day,
    lpad(pg_size_pretty(round(shared_hit_bytes_per_day)::bigint), 7)   AS shared_hit_bytes_per_day,
    lpad(pg_size_pretty(round(shared_read_bytes_per_day)::bigint), 7)  AS shared_read_bytes_per_day,
    lpad(pg_size_pretty(round(shared_write_bytes_per_day)::bigint), 7) AS shared_write_bytes_per_day
FROM rpt_stmt_totals_history_raw;

-- ---------------------------------------------------------------------
-- Synthetic: latest collection per instance — general health overview.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_latest_snapshot AS
WITH latest_job AS (
    SELECT instance, max(id_stat_collect_job) AS id_stat_collect_job
    FROM hist_pg_stat_database
    GROUP BY instance
)
SELECT
    d.instance,
    j.collect_start AS collected_at,
    d.numbackends AS connections,
    round(100.0 * d.blks_hit / nullif(d.blks_hit + d.blks_read, 0), 2) AS cache_hit_pct,
    d.xact_commit,
    d.xact_rollback,
    d.deadlocks,
    d.temp_files,
    pg_size_pretty(d.temp_bytes) AS temp_bytes_pretty
FROM latest_job lj
    JOIN hist_pg_stat_database d
        ON d.instance = lj.instance AND d.id_stat_collect_job = lj.id_stat_collect_job AND d.datname = :'app_database'
    JOIN stat_collect_job j ON j.id = lj.id_stat_collect_job AND j.instance = lj.instance
ORDER BY d.instance;

-- ---------------------------------------------------------------------
-- Synthetic: top 10 queries by total execution time, latest collection
-- per instance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_top_queries_latest AS
WITH latest_job AS (
    SELECT instance, max(id_stat_collect_job) AS id_stat_collect_job
    FROM hist_pg_stat_statements
    GROUP BY instance
),
ranked AS (
    SELECT
        s.instance,
        s.query,
        s.calls,
        s.total_exec_time,
        s.mean_exec_time,
        s.rows,
        row_number() OVER (PARTITION BY s.instance ORDER BY s.total_exec_time DESC) AS rn
    FROM latest_job lj
        JOIN hist_pg_stat_statements s
            ON s.instance = lj.instance AND s.id_stat_collect_job = lj.id_stat_collect_job
)
SELECT instance, query, calls, total_exec_time, mean_exec_time, rows
FROM ranked
WHERE rn <= 10
ORDER BY instance, total_exec_time DESC;

-- ---------------------------------------------------------------------
-- Synthetic: problematic indexes, latest collection per instance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_index_poor_latest AS
WITH latest_job AS (
    SELECT instance, max(id_stat_collect_job) AS id_stat_collect_job
    FROM hist_index_poor
    GROUP BY instance
)
SELECT
    p.instance, p.reason, p.schemaname, p.tablename, p.indexname,
    p.idx_scan, p.index_scan_pct, p.scans_per_write,
    pg_size_pretty(p.index_size) AS index_size_pretty,
    pg_size_pretty(p.table_size) AS table_size_pretty
FROM latest_job lj
    JOIN hist_index_poor p
        ON p.instance = lj.instance AND p.id_stat_collect_job = lj.id_stat_collect_job
ORDER BY p.instance, p.grp, p.index_size DESC;

-- ---------------------------------------------------------------------
-- Indexes flagged as never used in EVERY enabled instance at once
-- (strong drop candidates — idle everywhere means it's not just one
-- instance's traffic pattern). "Latest" here is the highest id in
-- stat_collect_job (the most recent job run overall), not the latest
-- per instance like rpt_index_poor_latest — if an enabled instance has
-- no data for that job (e.g. its collection failed), the tablename/
-- indexname pair is excluded until it reappears: you can't claim
-- "unused everywhere" without data from everywhere.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt_index_never_used_everywhere AS
WITH latest_job AS (
    SELECT max(id) AS id FROM stat_collect_job
),
enabled_instance_count AS (
    SELECT count(*) AS n FROM instance_config WHERE enabled
)
SELECT tablename, indexname
FROM hist_index_poor
WHERE reason = 'Never Used Indexes'
    AND id_stat_collect_job = (SELECT id FROM latest_job)
GROUP BY tablename, indexname
HAVING count(DISTINCT instance) = (SELECT n FROM enabled_instance_count);

-- Ownership of these views is transferred separately -- see
-- 08_reports_ownership.sql.
