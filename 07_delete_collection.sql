-- Removes all data for ONE collection (a stat_collect_job id) across
-- the 11 hist_* tables, then the stat_collect_job row itself (must be
-- last -- the hist_* tables FK to it). Returns rows deleted per table.
--   SELECT * FROM stats_collect.delete_collection(9);

CREATE OR REPLACE FUNCTION stats_collect.delete_collection(p_job_id bigint)
RETURNS TABLE(table_name text, rows_deleted bigint)
LANGUAGE plpgsql
AS $func$
DECLARE
    v_tbl   text;
    v_count bigint;
BEGIN
    FOREACH v_tbl IN ARRAY ARRAY[
        'hist_pg_stat_database', 'hist_pg_stat_database_conflicts',
        'hist_pg_statio_all_tables', 'hist_pg_statio_all_indexes',
        'hist_pg_stat_all_tables', 'hist_pg_stat_statements', 'hist_pg_stat_statements_info',
        'hist_schemas', 'hist_object_size', 'hist_tables_size', 'hist_index_poor'
    ] LOOP
        EXECUTE format('DELETE FROM stats_collect.%I WHERE id_stat_collect_job = $1', v_tbl)
            USING p_job_id;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        table_name := v_tbl;
        rows_deleted := v_count;
        RETURN NEXT;
    END LOOP;

    DELETE FROM stats_collect.stat_collect_job WHERE id = p_job_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    table_name := 'stat_collect_job';
    rows_deleted := v_count;
    RETURN NEXT;
END;
$func$;

ALTER FUNCTION stats_collect.delete_collection(bigint) OWNER TO stats_collect_owner;
