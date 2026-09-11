-- Run on the central stats database as admin. Requires
-- -v app_database=<name> (the application database name to filter
-- pg_stat_database rows down to -- deploy.py passes it from
-- config.yaml's job.runs_in):
--   psql <connection target> -v app_database=<name> -f 06_reports.sql

SET search_path = stats_collect;

CREATE OR REPLACE VIEW rpt_job_history AS
SELECT id, collect_start, collect_end,
       collect_end - collect_start AS duration
FROM stat_collect_job
ORDER BY collect_start DESC;

-- Historical: database size and commit/rollback rate per instance.
CREATE OR REPLACE VIEW rpt_db_activity_history AS
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
    JOIN stat_collect_job j ON j.id = d.id_stat_collect_job
WHERE d.datname = :'app_database'
ORDER BY j.collect_start DESC, d.instance;

-- Historical: schema size growth.
CREATE OR REPLACE VIEW rpt_schema_growth_history AS
SELECT
    j.collect_start::date AS collect_date,
    h.instance,
    h.nspname,
    h.size,
    pg_size_pretty(h.size) AS size_pretty,
    h.size_pct,
    h.tables
FROM hist_schemas h
    JOIN stat_collect_job j ON j.id = h.id_stat_collect_job
ORDER BY j.collect_start DESC, h.size DESC;

-- Synthetic: latest collection per instance.
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
    JOIN stat_collect_job j ON j.id = lj.id_stat_collect_job
ORDER BY d.instance;

-- Synthetic: top 10 queries by total execution time, latest per instance.
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

-- Synthetic: problematic indexes, latest per instance.
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

-- Indexes flagged "Never Used" in EVERY enabled instance at once, in
-- the most recent job overall (not per-instance latest) -- an enabled
-- instance missing from that job (e.g. its collection failed) excludes
-- the pair until it reappears in every instance's data at once.
CREATE OR REPLACE VIEW rpt_never_used_everywhere AS
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

DO $$
DECLARE
    v_view text;
BEGIN
    FOREACH v_view IN ARRAY ARRAY[
        'rpt_job_history', 'rpt_db_activity_history', 'rpt_schema_growth_history',
        'rpt_latest_snapshot', 'rpt_top_queries_latest', 'rpt_index_poor_latest',
        'rpt_never_used_everywhere'
    ] LOOP
        EXECUTE format('ALTER VIEW stats_collect.%I OWNER TO stats_collect_owner', v_view);
    END LOOP;
END $$;
