-- Run on the central stats database as admin, right after 06_reports.sql.
-- Requires -v schema=<name> -v owner_role=<role> (config.yaml's schema/
-- owner_role; deploy.py passes both automatically):
--
--   psql <connection target> -v schema=stats_collect -v owner_role=<role> -f 08_reports_ownership.sql
--
-- Kept separate from 06_reports.sql (which only CREATEs the views) so
-- the owner role comes from config.yaml instead of being hardcoded in
-- that file. Finds every view whose name starts with rpt_ dynamically
-- rather than a maintained list -- a new rpt_* view added to
-- 06_reports.sql is picked up automatically next run, no second file
-- to remember to update.
--
-- Both variables are routed through a GUC because psql substitution
-- doesn't reach inside this file's dollar-quoted DO block.
SET stats_collect_deploy.schema = :'schema';
SET stats_collect_deploy.owner_role = :'owner_role';

DO $$
DECLARE
    v_schema text := current_setting('stats_collect_deploy.schema');
    v_owner  text := current_setting('stats_collect_deploy.owner_role');
    v_view   text;
BEGIN
    FOR v_view IN
        SELECT viewname FROM pg_views
        WHERE schemaname = v_schema AND viewname LIKE 'rpt\_%' ESCAPE '\'
    LOOP
        EXECUTE format('ALTER VIEW %I.%I OWNER TO %I', v_schema, v_view, v_owner);
    END LOOP;
END $$;
