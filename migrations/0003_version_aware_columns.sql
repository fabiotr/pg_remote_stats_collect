-- =====================================================================
-- Release 0.3.0 migration -- see releases.yaml. Applied automatically
-- by `./deploy.py --migrate`.
--
-- WHY: the hist_pg_stat_* tables became a superset of every column
-- these views/pg_stat_statements have ever had (see 02_setup.sql). This
-- just widens the 6 tables that gained columns, all nullable; existing
-- rows are unaffected.
--
-- Not touched here: any instance's already-existing foreign tables
-- keep whatever columns they were created with -- copy_matching_columns()
-- already NULLs the difference. A foreign table only gains the new
-- tiered columns the next time setup_instance_fdw() runs for it.
-- =====================================================================

BEGIN;

ALTER TABLE :"schema".hist_pg_stat_database
    ADD COLUMN parallel_workers_to_launch bigint,
    ADD COLUMN parallel_workers_launched  bigint;

ALTER TABLE :"schema".hist_pg_stat_database_conflicts
    ADD COLUMN stats_reset timestamptz;

ALTER TABLE :"schema".hist_pg_statio_all_tables
    ADD COLUMN stats_reset timestamptz;

ALTER TABLE :"schema".hist_pg_statio_all_indexes
    ADD COLUMN stats_reset timestamptz;

ALTER TABLE :"schema".hist_pg_stat_all_tables
    ADD COLUMN total_vacuum_time      double precision,
    ADD COLUMN total_autovacuum_time  double precision,
    ADD COLUMN total_analyze_time     double precision,
    ADD COLUMN total_autoanalyze_time double precision,
    ADD COLUMN stats_reset            timestamptz;

ALTER TABLE :"schema".hist_pg_stat_statements
    ADD COLUMN total_time    double precision,
    ADD COLUMN min_time      double precision,
    ADD COLUMN max_time      double precision,
    ADD COLUMN mean_time     double precision,
    ADD COLUMN stddev_time   double precision,
    ADD COLUMN blk_read_time  double precision,
    ADD COLUMN blk_write_time double precision,
    ADD COLUMN wal_buffers_full     bigint,
    ADD COLUMN parallel_workers_to_launch bigint,
    ADD COLUMN parallel_workers_launched  bigint,
    ADD COLUMN generic_plan_calls bigint,
    ADD COLUMN custom_plan_calls  bigint;

COMMIT;
