# Cross-Instance Stats Collection

**Category:** Assessment (cross-instance historical monitoring)

> **Version support:** this version's schema and foreign-table column lists are hardcoded against **PostgreSQL 17**. It has not been adapted for other major versions yet — every source instance and the central database need to be on 17 (patch version, e.g. 17.4 vs 17.9, is fine). Adding multi-version support is on the roadmap; see `instance_config.pg_version` (tracked today, not yet acted on by anything) and the note in `02_setup.sql`.

A routine that periodically collects PostgreSQL statistics from any number of instances — via Foreign Data Wrapper, no per-instance manual connection required — and stores the history in one central database, so you can track trends over time (growing tables, index bloat, query regressions) instead of only ever seeing a point-in-time snapshot.

It complements the single-instance, point-in-time scripts in [`pg_scripts`](https://github.com/fabiotr/pg_scripts)'s `sql/` and the health-check style reports in its `reports/`: those tell you what an instance looks like *right now*; this stores that same kind of information *every time it runs*, across *every instance you configure*, so you can compare and trend.

## Requires

- `postgres_fdw` and `dblink` extensions on the central database (both installed by `02_setup.sql`).
- `pg_stat_statements` already enabled on every monitored instance (this routine doesn't install it).
- `pg_cron` on the central database — optional, only for scheduling (installed by `05_schedule_pg_cron.sql`).
- `psql` on `PATH`, and Python 3 with PyYAML (`pip install pyyaml`) to run `deploy.py`.
- A `.pg_service.conf` (or `$PGSERVICEFILE`) with one entry per distinct cluster — named exactly as that cluster's value in `config.yaml` — plus one entry for the central database, named exactly as `central_service`. `deploy.py` connects purely via `service=<name>`, never a host/port/password on the command line.

## Setup

1. Copy `config.yaml.example` to `config.yaml` and edit it for your topology (see the comments in the file).
2. `./deploy.py` — reads `config.yaml` and runs everything in order (see [Architecture](#architecture) for what each step does).

```bash
cp config.yaml.example config.yaml
$EDITOR config.yaml
./deploy.py
```

It's a fresh-environment tool, not an idempotent reconciler — re-running it against an already-deployed environment fails loudly the moment it hits something that already exists (no `IF NOT EXISTS` on role/schema/table/server creation, by design). For an already-deployed environment:

- **Reconcile it with the current `config.yaml`:** `./deploy.py --update` — adds instances newly listed, removes ones no longer listed (dropping their FDW objects, and the remote role too if it was the last instance on that cluster), and updates the rest to match (see its docstring for the details and one known edge case).
- **Just want the commands, not run for you:** `./deploy.py --generate-calls` — regenerates the FDW setup calls for whatever's currently in `instance_config`, printed for you to review.

Either mode ends with a password summary — capture it into a password manager, it's shown once and never stored.

## Architecture

### Roles

- **`stats_collect_owner`** (central database, `NOLOGIN`) — owns the `stats_collect` schema and everything in it. Never connects directly; `pg_cron` runs the job as this role through its internal worker, which doesn't need `LOGIN`. For manual testing, `SET ROLE stats_collect_owner` first.
- **`stats_collect_<cluster>`** — one per source **cluster**, not per instance (see below) — created via `01_remote_setup.sql`. Used only as the remote login for FDW connections; member of `pg_monitor` so it can read `pg_stat_statements` for every user, not just its own queries.

### Schema layout (`stats_collect`)

- `instance_name` — enum of every instance you monitor, built from `config.yaml`'s `instances[]` by `deploy.py`.
- `stat_collect_job` — one row per collection run: `id`, `collect_start`, `collect_end`, `status` (`running`/`succeeded`/`failed`), `errors`.
- `instance_config` — which instances participate and how to reach each one (`instance`, `fdw_server`, `host`, `port`, `database_name`, `remote_user`, `cluster`, `instance_type`, `enabled`, `sys_prefix`, `pg_version`, `notes`) — the single source of truth `setup_instance_fdw()` reads from. `cluster` is the instance's own name if it's a writer, or its writer's name if it's a reader (no separate is-writer flag needed). `instance_type`, `sys_prefix`, `pg_version` and `notes` are descriptive only — `collect_stats()` doesn't branch on them. Populated from `config.yaml` by `deploy.py`.
- 7 tables mirroring `pg_stat_database`, `pg_stat_database_conflicts`, `pg_statio_all_tables`, `pg_statio_all_indexes`, `pg_stat_all_tables`, `pg_stat_statements`, `pg_stat_statements_info` — same columns as the source, plus `id_stat_collect_job` + `instance`.
- 4 tables holding "raw" (unformatted) versions of four queries from [`pg_scripts`](https://github.com/fabiotr/pg_scripts)'s `sql/` directory — same logic/filters/`LIMIT` as `schemas_94up.sql`, `object_size_90up.sql`, `tables_size_95up.sql` and `index_poor_84up.sql`, with `pg_size_pretty`/`lpad`/`round(...)::text` replaced by the underlying numeric value: `hist_schemas`, `hist_object_size`, `hist_tables_size`, `hist_index_poor`.
- 13 reporting views (`rpt_*`), historical and synthetic — see [Reports](#reports).

### Connecting to source instances: FDW + dblink, and why both

The 7 direct stats tables are populated from **`postgres_fdw` foreign tables** — one per instance per view, mapped straight onto the remote `pg_catalog`/`public` view. The remote side evaluates its own view; safe regardless of the underlying function's volatility since nothing is computed locally.

The 4 raw queries call size functions (`pg_relation_size`, `pg_total_relation_size`, ...) that are `VOLATILE`, so `postgres_fdw` never pushes them down — a plain foreign table would compute those sizes against the *central* database's own catalog, silently wrong. Instead these run through **`dblink(server_name, query_text)`**, which sends the whole query text to the remote server to execute entirely there. `dblink_connect` reuses the same `FOREIGN SERVER`/`USER MAPPING` created for the FDW tables.

### One role per cluster, not per instance

Read replicas of the same cluster share the writer's catalog and reject write statements — so `CREATE ROLE` only needs to run once, on the writer, per cluster. `01_remote_setup.sql` is meant to be run once per cluster; `setup_instance_fdw()` still runs once per **instance** (each gets its own `FOREIGN SERVER` pointed at its own host, even when several share one remote role).

### Collection procedure (`stats_collect.collect_stats()`)

- Opens a `stat_collect_job` row (`status = 'running'`) and commits immediately.
- Loops over every `enabled` row in `instance_config`, each wrapped in its own `BEGIN … EXCEPTION WHEN OTHERS`: one instance's failure only discards that instance's data for the run — the rest continue. The error is appended to `stat_collect_job.errors`.
- `COMMIT`s after each instance, so a killed job keeps whatever was already collected.
- `RAISE NOTICE` at every step, visible in an interactive `psql` session.
- Ends `'succeeded'` only if `errors` is empty; otherwise `'failed'`, even if most instances succeeded.

**Design constraint:** this procedure can't have a `SET` clause or be `SECURITY DEFINER` — PostgreSQL rejects internal `COMMIT`/`ROLLBACK` in both cases. That's why every reference inside it is schema-qualified instead of relying on `search_path`, and why it stays `SECURITY INVOKER` — `pg_cron` already runs it as `stats_collect_owner`.

### Scheduling

`pg_cron`'s metadata always lives in the `postgres` database on RDS/Aurora, regardless of which database the job should run in. Per AWS's documented procedure ([scheduling a cron job for a database other than the default](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL_pg_cron.html#PostgreSQL_pg_cron.otherDB)): the extension is created in `postgres`, the job is scheduled there with `cron.schedule(...)`, then `UPDATE cron.job` redirects it to the target database/role. Off RDS/Aurora, `cron.schedule_in_database(...)` does this in one call.

### Reports

| View | Kind | What it shows |
|---|---|---|
| `rpt_job_history` | historical | every job run, with duration |
| `rpt_db_activity_history_raw` | historical | same as below, plain numeric (temp_bytes in bytes) — for further processing rather than direct reading |
| `rpt_db_activity_history` | historical | connections, commit/rollback, cache hit %, temp files, deadlocks per instance over time, formatted for direct reading |
| `rpt_schema_growth_history_raw` | historical | same as below, plain numeric (size in bytes) — for further processing rather than direct reading |
| `rpt_schema_growth_history` | historical | schema size trend per instance, formatted for direct reading |
| `rpt_tables_size_history_raw` | historical | same as below, plain numeric (sizes in bytes) — for further processing rather than direct reading |
| `rpt_tables_size_history` | historical | size trend of the 20 largest tables per instance (replicas omitted — same size as their writer), with month-over-month growth (extrapolated to 30 days) and an estimated annual growth (extrapolated to 365 days), formatted for direct reading |
| `rpt_stmt_totals_history_raw` | historical | same as below, plain numeric (ms, bytes) — for further processing (charts, aggregation) rather than direct reading |
| `rpt_stmt_totals_history` | historical | `pg_stat_statements` totals for the app database, per instance, normalized to a "/day" rate since the tracked `stats_reset`, formatted for direct reading — based on [`pg_scripts`](https://github.com/fabiotr/pg_scripts)'s `statements_cluster_total_17up.sql` |
| `rpt_latest_snapshot` | synthetic | latest-job health snapshot per instance |
| `rpt_top_queries_latest` | synthetic | top 10 queries by total execution time, latest job per instance |
| `rpt_index_poor_latest` | synthetic | problematic indexes, latest job per instance |
| `rpt_never_used_everywhere` | synthetic | indexes flagged "Never Used" in **every** enabled instance simultaneously, in the most recent job overall — strong drop candidates |

## Setup order (manual, if not using `deploy.py`)

`01` runs on each source cluster's writer; `02`–`08` run on the central stats database.

| # | File | Runs on | What it does |
|---|---|---|---|
| 1 | `01_remote_setup.sql` | each cluster's writer (`-v role_name=... -v role_password=...`) | Creates the remote login role, grants `pg_monitor` |
| 2 | `02_setup.sql` (`-v instance_name_values=...`) | central | Owner role, schema, types, tables |
| 3 | `03_fdw_setup.sql` | central | Defines `setup_instance_fdw()` |
| 4 | `04_collect_procedure.sql` | central | Defines `collect_stats()` |
| 5 | `05_schedule_pg_cron.sql` | central, `postgres` db | Installs `pg_cron`, schedules the job |
| 6 | `06_reports.sql` (`-v app_database=...`) | central | Creates the 13 `rpt_*` views |
| 7 | `07_delete_collection.sql` | central | Defines `delete_collection(job_id)` |
| 8 | `08_reports_ownership.sql` (`-v owner_role=...`) | central | Transfers ownership of every `rpt_*` view to the owner role — kept separate so the role isn't hardcoded in `06_reports.sql`; discovers the views dynamically, no list to keep in sync |

## Common operations

**Run the collection manually:**

```sql
SET ROLE stats_collect_owner;
CALL stats_collect.collect_stats();
RESET ROLE;
```

Run each statement separately — combining them into one multi-statement command wraps them in an implicit transaction and breaks the internal `COMMIT`.

**Check the outcome:**

```sql
SELECT * FROM stats_collect.stat_collect_job ORDER BY id DESC LIMIT 1;
```

**Delete a bad or test collection:**

```sql
SELECT * FROM stats_collect.delete_collection(9);
```

**Add, remove, or update an instance:** edit `config.yaml`'s `instances[]` accordingly (add a row, delete one, or change its values), then `./deploy.py --update`.

## Other existing functions

Beyond `collect_stats()` and `setup_instance_fdw()` (both covered above), these also exist and are meant to be called directly when needed:

| Function/command | Where | What it does |
|---|---|---|
| `stats_collect.delete_collection(p_job_id bigint)` | central db, SQL function | Deletes one collection's rows from all 11 `hist_*` tables plus its `stat_collect_job` row — see [Common operations](#common-operations). |
| `./deploy.py --update [config.yaml]` | CLI | Reconciles the live `instance_config` with `config.yaml` — adds, removes, and updates instances as needed. |
| `./deploy.py --generate-calls [config.yaml]` | CLI | Prints (doesn't run) the `01_remote_setup.sql`/`setup_instance_fdw()` commands for whatever's currently in `instance_config`. |

## License

BSD 3-Clause, same as the rest of this author's PostgreSQL tooling — see `LICENSE`.
