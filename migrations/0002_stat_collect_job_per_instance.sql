-- =====================================================================
-- Release 0.2.0 migration -- see releases.yaml. Applied automatically
-- by `./deploy.py --migrate` against an already-deployed environment;
-- run directly with psql only if you're not using deploy.py:
--
--   psql <connection target> -v schema=stats_collect -f migrations/0002_stat_collect_job_per_instance.sql
--
-- After this runs (by either path), also re-run 06_reports.sql and
-- 08_reports_ownership.sql -- their view definitions changed to match.
--
-- WHY: stat_collect_job moved from one row per collection RUN to one
-- row per (run, INSTANCE) -- see 02_setup.sql and 04_collect_procedure.sql.
-- Existing rows predate that: one row covered the whole run, not one
-- instance. This script reconstructs one row per (job, instance) for
-- every instance that actually has data for that job, then rebuilds
-- the primary key and every hist_* table's foreign key to match.
--
-- HOW instances are matched to old jobs: collect_stats() treats each
-- instance as one atomic all-or-nothing block (its own BEGIN ...
-- EXCEPTION, rolled back to a savepoint on any error) -- so if an
-- instance succeeded at all, it left a hist_pg_stat_database row (the
-- first of its 11 inserts); if it failed, NONE of its inserts survived.
-- So hist_pg_stat_database is a reliable proxy for "this instance
-- succeeded in this job", and is what this script joins against.
--
-- KNOWN LIMITATION: an instance that FAILED under the old schema does
-- NOT get its own reconstructed row here (nothing references it, since
-- it left no hist_* rows either) -- its per-instance failure detail
-- (originally folded into the old job's one shared `errors` array) is
-- not split back out. Nothing is lost, though: the pre-migration table
-- is kept as stat_collect_job_pre_migration (see below) with the
-- original errors array intact, for reference. Drop that table
-- yourself once you've confirmed you don't need it.
--
-- version is backfilled from instance_config.pg_version, parsed from
-- its "MAJOR.MINOR" text (e.g. "17.4") into the same encoding
-- server_version_num uses (major * 10000 + minor, e.g. 170004 --
-- verified empirically: PG 15.18 reports server_version_num 150018).
-- Assumes pg_version is always exactly two dot-separated integers,
-- true for every value config.yaml has ever held. Only left NULL for
-- an instance with no matching instance_config row (shouldn't happen
-- in practice).
-- =====================================================================

BEGIN;

-- Keep the pre-migration table around for reference (original 1-row-
-- per-job data, including the old shared `errors` array) -- drop it
-- yourself once you're confident you don't need it.
CREATE TABLE :"schema".stat_collect_job_pre_migration AS
    SELECT * FROM :"schema".stat_collect_job;

-- ---- 1. Drop every hist_* table's existing FK (single-column, to id) ----
ALTER TABLE :"schema".hist_pg_stat_database           DROP CONSTRAINT hist_pg_stat_database_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_stat_database_conflicts  DROP CONSTRAINT hist_pg_stat_database_conflicts_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_statio_all_tables        DROP CONSTRAINT hist_pg_statio_all_tables_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_statio_all_indexes       DROP CONSTRAINT hist_pg_statio_all_indexes_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_stat_all_tables          DROP CONSTRAINT hist_pg_stat_all_tables_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_stat_statements          DROP CONSTRAINT hist_pg_stat_statements_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_pg_stat_statements_info     DROP CONSTRAINT hist_pg_stat_statements_info_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_schemas                     DROP CONSTRAINT hist_schemas_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_object_size                 DROP CONSTRAINT hist_object_size_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_tables_size                 DROP CONSTRAINT hist_tables_size_id_stat_collect_job_fkey;
ALTER TABLE :"schema".hist_index_poor                  DROP CONSTRAINT hist_index_poor_id_stat_collect_job_fkey;

-- ---- 2. Add the new columns (nullable for now), and drop the OLD
-- single-column primary key -- it would otherwise reject the exploded
-- per-instance rows in step 3 below (several rows sharing the same id).
ALTER TABLE :"schema".stat_collect_job ADD COLUMN instance :"schema".instance_name;
ALTER TABLE :"schema".stat_collect_job ADD COLUMN version numeric;
ALTER TABLE :"schema".stat_collect_job DROP CONSTRAINT stat_collect_job_pkey;

-- ---- 3. Explode each old job row into one row per instance with data ----
INSERT INTO :"schema".stat_collect_job (id, instance, version, collect_start, collect_end, status, errors)
SELECT j.id, d.instance, NULL, j.collect_start, j.collect_end, j.status, '{}'::text[]
FROM :"schema".stat_collect_job j
    JOIN (SELECT DISTINCT id_stat_collect_job, instance FROM :"schema".hist_pg_stat_database) d
        ON d.id_stat_collect_job = j.id
WHERE j.instance IS NULL;

-- Remove the original one-row-per-job rows now that they've been
-- exploded (a job with zero successful instances leaves no exploded
-- row and is simply dropped here -- it has nothing for any FK to
-- reference anyway).
DELETE FROM :"schema".stat_collect_job WHERE instance IS NULL;

-- ---- 4. Enforce instance NOT NULL and add the new composite primary key ----
ALTER TABLE :"schema".stat_collect_job ALTER COLUMN instance SET NOT NULL;
ALTER TABLE :"schema".stat_collect_job ADD PRIMARY KEY (id, instance);

-- ---- 5. Recreate every hist_* table's FK as composite ----
ALTER TABLE :"schema".hist_pg_stat_database           ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_stat_database_conflicts  ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_statio_all_tables        ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_statio_all_indexes       ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_stat_all_tables          ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_stat_statements          ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_pg_stat_statements_info     ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_schemas                     ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_object_size                 ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_tables_size                 ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);
ALTER TABLE :"schema".hist_index_poor                  ADD FOREIGN KEY (id_stat_collect_job, instance) REFERENCES :"schema".stat_collect_job (id, instance);

-- ---- 6. Backfill version from instance_config.pg_version before it's dropped ----
UPDATE :"schema".stat_collect_job job
SET version = split_part(ic.pg_version, '.', 1)::int * 10000 + split_part(ic.pg_version, '.', 2)::int
FROM :"schema".instance_config ic
WHERE ic.instance = job.instance AND job.version IS NULL;

-- ---- 7. instance_config.pg_version is superseded by stat_collect_job.version ----
ALTER TABLE :"schema".instance_config DROP COLUMN pg_version;

COMMIT;
