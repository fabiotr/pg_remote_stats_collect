-- pg_cron scheduling for the monthly job. Requires -v job_name=<name>
-- -v job_schedule="'<cron expr>'" -v job_command="'<sql>'"
-- -v job_runs_in=<target_db> -v job_run_as=<role> (deploy.py passes
-- these from config.yaml's job{} automatically).
--
-- Requires pg_cron already in shared_preload_libraries (on RDS/Aurora:
-- a parameter-group change plus a writer reboot -- an AWS console/CLI
-- action, not something this file can do).
--
-- On RDS/Aurora, pg_cron's metadata always lives in the "postgres"
-- database regardless of cron.database_name, and there's no
-- cron.schedule_in_database() -- instead: connect to "postgres" (this
-- file must run there, e.g. `psql "<target> dbname=postgres" -f ...`),
-- schedule with cron.schedule() (created pointing at "postgres"), then
-- UPDATE cron.job to redirect it. See AWS's docs on "Scheduling a cron
-- job for a database other than the default database". Off RDS/Aurora,
-- just use cron.schedule_in_database(...) directly instead of this file.

CREATE EXTENSION IF NOT EXISTS pg_cron;

GRANT USAGE ON SCHEMA cron TO :"job_run_as";

SELECT cron.schedule(:'job_name', :'job_schedule', :'job_command');

UPDATE cron.job
SET database = :'job_runs_in',
    username = :'job_run_as'
WHERE jobname = :'job_name';

-- Verify:   SELECT jobid, schedule, command, database, username, active, jobname FROM cron.job;
-- Runs:     SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
-- Unschedule: SELECT cron.unschedule('<job_name>');
