#!/usr/bin/env python3
"""Deploy orchestrator: reads config.yaml and runs 01..07 in order
against a fresh (or partially fresh) environment.

  1. One CREATE ROLE per distinct cluster in config.yaml
     (01_remote_setup.sql), via a pg_service.conf entry matching the
     cluster value itself (a writer's cluster == its own name -- see
     config.yaml.example's comment on the cluster field).
  2. 02_setup.sql -- schema, owner role, types, tables.
  3. 03_fdw_setup.sql -- defines setup_instance_fdw() (no data, no
     CALLs -- every environment-specific value lives in config.yaml).
  4. One INSERT INTO instance_config per instance in config.yaml.
  5. One CALL setup_instance_fdw(instance, password) per instance.
  6. 04_collect_procedure.sql.
  7. 05_schedule_pg_cron.sql, against the "postgres" database (pg_cron's
     metadata lives there on RDS/Aurora -- see that file's header).
     Requires pg_cron already in shared_preload_libraries.
  8. 06_reports.sql (with -v app_database=<job.runs_in>),
     08_reports_ownership.sql (with -v owner_role=<owner_role>),
     07_delete_collection.sql.

Every password generated is printed once at the end (grouped by remote
user/database) -- capture it into a password manager, it's not stored.

Usage:
    ./deploy.py [config.yaml]
    (default: config.yaml; the central database connection comes from
    its central_service, not a CLI argument)

    ./deploy.py --generate-calls [config.yaml]
    Already-deployed environment: (re)generates the 01_remote_setup.sql
    and setup_instance_fdw() calls for whatever's currently in
    instance_config, with a fresh password per cluster. Reads the live
    table, not config.yaml; prints commands for you to review and run.

    ./deploy.py --update [config.yaml]
    Already-deployed environment: reconciles it with config.yaml, in
    three passes -- add, remove, update -- each a no-op if there's
    nothing for it to do:
      - Removed from config.yaml: FDW objects dropped (DROP SERVER
        CASCADE, taking the USER MAPPING and 7 foreign tables with it),
        instance_config row deleted, and -- if that was the last
        instance on its cluster -- the remote role too (best-effort:
        a warning is printed and the run continues if it still owns
        other objects there).
      - Present in both but changed: instance_config updated to match,
        and if fdw_server/host/port/database_name/remote_user changed,
        the FOREIGN SERVER/USER MAPPING updated too. Passwords aren't
        touched by this path.
      - New in config.yaml: a fresh remote role for a brand-new
        cluster, or (joining a cluster that's already deployed) a
        password reset for that cluster's role with every existing
        sibling instance's USER MAPPING resynced, since the password
        was never stored from the original deploy.
    Known edge case: removing every instance of a cluster while also
    adding a new one that reuses that same cluster name, in the same
    run, isn't handled -- split it into two separate --update runs.

Requires: psql on PATH, PyYAML (`pip install pyyaml`).

Safe to re-run only up to the first step that hits an object that
already exists (no IF NOT EXISTS on role/schema/table/server creation,
by design) -- this is a fresh-environment tool, not an idempotent
reconciler. --update is the exception, built to be safe to re-run.
"""
import os
import secrets
import string
import subprocess
import sys
from pathlib import Path

import yaml

ALPHABET = string.ascii_letters + string.digits


def gen_password(length: int = 24) -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(length))


def sql_str(value: str) -> str:
    """Quote a plain Python string as a SQL string literal."""
    return "'" + value.replace("'", "''") + "'"


def run(args: list[str]) -> None:
    result = subprocess.run(args)
    if result.returncode != 0:
        sys.exit(result.returncode)


def run_psql_file(conn: str, path: str, variables: dict[str, str] | None = None) -> None:
    args = ["psql", conn, "-X", "-v", "ON_ERROR_STOP=1"]
    for name, value in (variables or {}).items():
        args += ["-v", f"{name}={value}"]
    args += ["-f", path]
    run(args)


def run_psql_command(conn: str, command: str) -> None:
    run(["psql", conn, "-X", "-v", "ON_ERROR_STOP=1", "-c", command])


def run_psql_command_allow_fail(conn: str, command: str) -> bool:
    """Like run_psql_command, but returns False instead of exiting --
    for steps allowed to fail without aborting the rest of the run
    (e.g. dropping a remote role that still owns other objects)."""
    result = subprocess.run(["psql", conn, "-X", "-v", "ON_ERROR_STOP=1", "-c", command])
    return result.returncode == 0


def run_psql_query(conn: str, query: str) -> str:
    """Read-only query; returns unaligned tuples-only stdout, one row
    per line."""
    result = subprocess.run(
        ["psql", conn, "-X", "-tAc", query], capture_output=True, text=True
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    return result.stdout


def print_password_summary(entries: list[tuple[str, str, str, list[str]]]) -> None:
    print()
    print("==> Passwords generated this run -- store these now, they will not be shown again:")
    for remote_user, password, databases, instance_names in entries:
        print(f"    user={remote_user}  database(s)={databases}  password={password}")
        print(f"        instances: {', '.join(instance_names)}")


def validate_writers(instances: list[dict], config_path: Path) -> None:
    """Every instance's cluster must resolve to a real writer -- an
    instance whose own cluster equals its own name."""
    writer_names = {inst["name"] for inst in instances if inst["cluster"] == inst["name"]}
    for inst in instances:
        if inst["cluster"] not in writer_names:
            sys.exit(
                f"ERROR: instance '{inst['name']}' has cluster: {inst['cluster']}, but "
                f"no instance named '{inst['cluster']}' has cluster == its own name "
                f"(the writer) in {config_path}"
            )


def instance_config_values(inst: dict) -> str:
    return "({instance}, {fdw_server}, {host}, {port}, {database_name}, {remote_user}, {cluster}, {instance_type}, {sys_prefix}, {pg_version}, {notes})".format(
        instance=sql_str(inst["name"]),
        fdw_server=sql_str(inst["fdw_server"]),
        host=sql_str(inst["host"]),
        port=int(inst["port"]),
        database_name=sql_str(inst["database_name"]),
        remote_user=sql_str(inst["remote_user"]),
        cluster=sql_str(inst["cluster"]),
        instance_type=sql_str(inst["instance_type"]),
        sys_prefix=sql_str(inst["sys_prefix"]),
        pg_version=sql_str(str(inst["pg_version"])),
        notes=sql_str(inst["notes"]) if inst.get("notes") else "NULL",
    )


INSTANCE_CONFIG_COLUMNS = (
    "instance, fdw_server, host, port, database_name, remote_user, cluster, instance_type, sys_prefix, pg_version, notes"
)

# Columns compared/read for --update's reconciliation (instance itself
# is split out as the dict key -- see parse_live_instance_config).
LIVE_INSTANCE_COLUMNS = (
    "fdw_server", "host", "port", "database_name", "remote_user",
    "cluster", "instance_type", "sys_prefix", "pg_version", "enabled", "notes",
)

# Which of the columns above affect the FDW objects (FOREIGN SERVER /
# USER MAPPING), as opposed to being instance_config-only metadata.
FDW_RELEVANT_COLUMNS = ("fdw_server", "host", "port", "database_name", "remote_user")


def parse_live_instance_config(central_conn: str) -> dict[str, dict[str, str]]:
    """{instance: {column: value}} for every row in instance_config,
    values as plain strings exactly as psql prints them -- compare
    with instance_yaml_value() rather than assuming a type."""
    raw = run_psql_query(
        central_conn,
        "SELECT instance || '|' || " + " || '|' || ".join(LIVE_INSTANCE_COLUMNS).replace(
            "notes", "coalesce(notes, '')"
        ) + " FROM stats_collect.instance_config ORDER BY instance;",
    )
    live: dict[str, dict[str, str]] = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("|", len(LIVE_INSTANCE_COLUMNS))
        live[parts[0]] = dict(zip(LIVE_INSTANCE_COLUMNS, parts[1:]))
    return live


def instance_yaml_value(inst: dict, column: str) -> str:
    """Renders one instances[] entry's value the same way
    parse_live_instance_config renders the database's, so the two can
    be compared directly as strings."""
    if column == "enabled":
        # A boolean concatenated with "||" casts to 'true'/'false', not
        # psql's usual single-column 't'/'f' display.
        return "true" if inst.get("enabled", True) else "false"
    if column == "notes":
        return inst.get("notes") or ""
    if column in ("port", "pg_version"):
        return str(inst[column])
    return inst[column]


def instance_matches_live(inst: dict, live_row: dict[str, str]) -> bool:
    return all(
        instance_yaml_value(inst, column) == live_row[column]
        for column in LIVE_INSTANCE_COLUMNS
    )


def generate_setup_calls(central_conn: str) -> None:
    """For an already-deployed environment: (re)generates the
    01_remote_setup.sql and setup_instance_fdw() calls for whatever is
    currently in instance_config -- typically after adding one new
    instance by hand.

    One password per DISTINCT cluster (a real instance_config column):
    several instances share one remote role within a cluster, and two
    distinct clusters can share a remote_user name too, so grouping by
    remote_user alone would wrongly conflate them.
    """
    raw = run_psql_query(
        central_conn,
        "SELECT instance || '|' || cluster || '|' || remote_user || '|' || host || '|' || database_name "
        "FROM stats_collect.instance_config ORDER BY cluster, instance;",
    )
    rows = [line.split("|") for line in raw.splitlines() if line.strip()]
    if not rows:
        sys.exit("No rows in stats_collect.instance_config -- nothing to generate.")

    password_for_cluster: dict[str, str] = {}
    remote_user_for_cluster: dict[str, str] = {}
    hosts_for_cluster: dict[str, list[str]] = {}
    databases_for_cluster: dict[str, set[str]] = {}
    instances_for_cluster: dict[str, list[str]] = {}
    for instance, cluster, remote_user, host, database_name in rows:
        if cluster not in password_for_cluster:
            password_for_cluster[cluster] = gen_password()
            remote_user_for_cluster[cluster] = remote_user
            hosts_for_cluster[cluster] = []
            databases_for_cluster[cluster] = set()
            instances_for_cluster[cluster] = []
        hosts_for_cluster[cluster].append(f"{host} ({instance})")
        databases_for_cluster[cluster].add(database_name)
        instances_for_cluster[cluster].append(instance)

    print("# =============================================================")
    print("# Step 1 -- run once per cluster, on the writer.")
    print("# =============================================================")
    for cluster, hosts in hosts_for_cluster.items():
        password = password_for_cluster[cluster]
        remote_user = remote_user_for_cluster[cluster]
        print()
        print(f"# cluster={cluster} role={remote_user} -- instances: {'; '.join(hosts)}")
        print(
            f'psql "service={cluster}" -v role_name={remote_user} '
            f'-v role_password="\'{password}\'" -f 01_remote_setup.sql'
        )

    print()
    print("# =============================================================")
    print("# Step 2 -- one call per instance, using its cluster's password.")
    print("# Run after step 1 above has actually created each role.")
    print("# =============================================================")
    for instance, cluster, _remote_user, _host, _database_name in rows:
        password = password_for_cluster[cluster]
        print(f"CALL stats_collect.setup_instance_fdw('{instance}', '{password}');")

    print_password_summary([
        (
            remote_user_for_cluster[cluster],
            password_for_cluster[cluster],
            ",".join(sorted(databases_for_cluster[cluster])),
            instances_for_cluster[cluster],
        )
        for cluster in password_for_cluster
    ])


def update_deploy(config_path: Path, cfg: dict) -> None:
    """--update: reconciles an already-deployed environment with
    config.yaml -- see the module docstring for the three passes
    (remove/update/add) and the one known edge case.
    """
    owner_role = cfg["owner_role"]
    central_conn = f"service={cfg['central_service']}"
    instances = cfg["instances"]

    validate_writers(instances, config_path)

    live = parse_live_instance_config(central_conn)
    config_by_name = {inst["name"]: inst for inst in instances}

    new_instances = [inst for inst in instances if inst["name"] not in live]
    removed_names = [name for name in live if name not in config_by_name]
    changed_instances = [
        inst for name, inst in config_by_name.items()
        if name in live and not instance_matches_live(inst, live[name])
    ]

    if not new_instances and not removed_names and not changed_instances:
        print("Nothing to do -- instance_config already matches config.yaml.")
        return

    print(
        f"Found {len(new_instances)} new, {len(removed_names)} removed, "
        f"{len(changed_instances)} changed instance(s)."
    )

    # ---- Removals ---------------------------------------------------
    removed_by_cluster: dict[str, list[str]] = {}
    for name in removed_names:
        removed_by_cluster.setdefault(live[name]["cluster"], []).append(name)

    for name in removed_names:
        row = live[name]
        print(f"==> Removing instance '{name}' (cluster={row['cluster']})")
        run_psql_command(central_conn, f"DROP SERVER IF EXISTS {row['fdw_server']} CASCADE;")
        run_psql_command(
            central_conn,
            f"DELETE FROM stats_collect.instance_config WHERE instance = {sql_str(name)};",
        )

    config_clusters = {inst["cluster"] for inst in instances}
    for cluster, names_removed in removed_by_cluster.items():
        still_needed = cluster in config_clusters or any(
            live_name not in removed_names and live[live_name]["cluster"] == cluster
            for live_name in live
        )
        if still_needed:
            continue
        remote_user = live[names_removed[0]]["remote_user"]
        print(f"==> Cluster '{cluster}' has no instances left -- dropping remote role '{remote_user}'")
        if not run_psql_command_allow_fail(f"service={cluster}", f"DROP ROLE IF EXISTS {remote_user};"):
            print(
                f"    WARNING: could not drop role '{remote_user}' on cluster "
                f"'{cluster}' (it may still own other objects there) -- left in place."
            )

    # ---- Updates to existing instances -------------------------------
    for inst in changed_instances:
        name = inst["name"]
        old = live[name]
        print(f"==> Updating instance '{name}'")
        run_psql_command(
            central_conn,
            "UPDATE stats_collect.instance_config SET "
            f"fdw_server = {sql_str(inst['fdw_server'])}, "
            f"host = {sql_str(inst['host'])}, "
            f"port = {int(inst['port'])}, "
            f"database_name = {sql_str(inst['database_name'])}, "
            f"remote_user = {sql_str(inst['remote_user'])}, "
            f"cluster = {sql_str(inst['cluster'])}, "
            f"instance_type = {sql_str(inst['instance_type'])}, "
            f"sys_prefix = {sql_str(inst['sys_prefix'])}, "
            f"pg_version = {sql_str(str(inst['pg_version']))}, "
            f"enabled = {'true' if inst.get('enabled', True) else 'false'}, "
            f"notes = {sql_str(inst['notes']) if inst.get('notes') else 'NULL'} "
            f"WHERE instance = {sql_str(name)};",
        )

        if all(instance_yaml_value(inst, c) == old[c] for c in FDW_RELEVANT_COLUMNS):
            continue  # only descriptive columns changed -- no FDW object to touch

        fdw_server = old["fdw_server"]
        if inst["fdw_server"] != old["fdw_server"]:
            print(f"    - renaming FOREIGN SERVER {old['fdw_server']} -> {inst['fdw_server']}")
            run_psql_command(central_conn, f"ALTER SERVER {old['fdw_server']} RENAME TO {inst['fdw_server']};")
            fdw_server = inst["fdw_server"]

        if (inst["host"] != old["host"] or str(inst["port"]) != old["port"]
                or inst["database_name"] != old["database_name"]):
            print(f"    - updating FOREIGN SERVER {fdw_server} connection options")
            run_psql_command(
                central_conn,
                f"ALTER SERVER {fdw_server} OPTIONS "
                f"(SET host {sql_str(inst['host'])}, SET port {sql_str(str(inst['port']))}, "
                f"SET dbname {sql_str(inst['database_name'])});",
            )

        if inst["remote_user"] != old["remote_user"]:
            print(f"    - updating USER MAPPING remote user for {fdw_server}")
            run_psql_command(
                central_conn,
                f"ALTER USER MAPPING FOR {owner_role} SERVER {fdw_server} "
                f"OPTIONS (SET user {sql_str(inst['remote_user'])});",
            )

    # ---- Additions ---------------------------------------------------
    existing_clusters = {live[n]["cluster"] for n in live if n not in removed_names}
    existing_fdw_servers_by_cluster: dict[str, list[str]] = {}
    for n in live:
        if n in removed_names:
            continue
        existing_fdw_servers_by_cluster.setdefault(live[n]["cluster"], []).append(live[n]["fdw_server"])

    new_by_cluster: dict[str, list[dict]] = {}
    for inst in new_instances:
        new_by_cluster.setdefault(inst["cluster"], []).append(inst)

    password_summary: list[tuple[str, str, str, list[str]]] = []

    for cluster, group in new_by_cluster.items():
        remote_user = group[0]["remote_user"]
        password = gen_password()

        if cluster not in existing_clusters:
            print(f"==> New cluster '{cluster}': creating remote role (01_remote_setup.sql)")
            run([
                "psql", f"service={cluster}", "-X", "-v", "ON_ERROR_STOP=1",
                "-v", f"role_name={remote_user}",
                "-v", f"role_password='{password}'",
                "-f", "01_remote_setup.sql",
            ])
        else:
            print(
                f"==> Cluster '{cluster}' already deployed: resetting its role's "
                f"password and updating every existing sibling instance's USER MAPPING"
            )
            run_psql_command(
                f"service={cluster}",
                f"ALTER ROLE {remote_user} PASSWORD '{password}';",
            )
            for fdw_server in existing_fdw_servers_by_cluster.get(cluster, []):
                run_psql_command(
                    central_conn,
                    f"ALTER USER MAPPING FOR {owner_role} SERVER {fdw_server} "
                    f"OPTIONS (SET password '{password}');",
                )

        for inst in group:
            print(f"    - adding instance {inst['name']}")
            # instance is an instance_name ENUM with a fixed value set from
            # 02_setup.sql -- a name added later needs a value added to
            # the type first (separate statement: a value can't be used
            # in the same transaction it was added in).
            run_psql_command(
                central_conn,
                f"ALTER TYPE stats_collect.instance_name ADD VALUE IF NOT EXISTS {sql_str(inst['name'])};",
            )
            run_psql_command(
                central_conn,
                f"INSERT INTO stats_collect.instance_config ({INSTANCE_CONFIG_COLUMNS}) "
                f"VALUES {instance_config_values(inst)};",
            )
            run_psql_command(
                central_conn,
                f"CALL stats_collect.setup_instance_fdw('{inst['name']}', '{password}');",
            )

        databases = ",".join(sorted({inst["database_name"] for inst in group}))
        password_summary.append((remote_user, password, databases, [inst["name"] for inst in group]))

    if password_summary:
        print_password_summary(password_summary)


def main() -> None:
    argv = sys.argv[1:]
    generate_calls_only = "--generate-calls" in argv
    update_only = "--update" in argv
    if generate_calls_only and update_only:
        sys.exit("ERROR: pass only one of --generate-calls / --update")
    argv = [a for a in argv if a not in ("--generate-calls", "--update")]

    config_path = Path(argv[0] if argv else "config.yaml")
    if not config_path.is_file():
        sys.exit(f"ERROR: config file not found: {config_path}")

    os.chdir(Path(__file__).resolve().parent)

    cfg = yaml.safe_load(config_path.read_text())
    central_conn = f"service={cfg['central_service']}"

    if generate_calls_only:
        generate_setup_calls(central_conn)
        return

    if update_only:
        update_deploy(config_path, cfg)
        return

    schema = cfg["schema"]
    owner_role = cfg["owner_role"]
    job_name = cfg["job"]["name"]
    instances = cfg["instances"]

    # config.yaml claiming a different schema/owner than what
    # 02_setup.sql actually creates would silently deploy the wrong
    # thing -- 03/04/etc. all assume stats_collect/stats_collect_owner.
    expected_line = f"CREATE SCHEMA {schema} AUTHORIZATION {owner_role};"
    if expected_line not in Path("02_setup.sql").read_text():
        sys.exit(
            f"ERROR: config.yaml's schema ({schema}) / owner_role ({owner_role}) "
            "don't match the CREATE SCHEMA line in 02_setup.sql. "
            "Update one or the other before deploying."
        )

    instance_name_values = ",".join(f"'{inst['name']}'" for inst in instances)

    validate_writers(instances, config_path)

    # One random password per CLUSTER, not per instance and not per
    # remote_user -- two distinct clusters can share a remote_user name.
    password_for_cluster: dict[str, str] = {}
    remote_user_for_cluster: dict[str, str] = {}
    for inst in instances:
        cluster = inst["cluster"]
        if cluster not in password_for_cluster:
            password_for_cluster[cluster] = gen_password()
            remote_user_for_cluster[cluster] = inst["remote_user"]

    print("==> Step 1/8: creating remote roles (01_remote_setup.sql), one per cluster")
    for cluster, password in password_for_cluster.items():
        remote_user = remote_user_for_cluster[cluster]
        print(f"    - cluster={cluster} role={remote_user} via service={cluster}")
        run([
            "psql", f"service={cluster}", "-X", "-v", "ON_ERROR_STOP=1",
            "-v", f"role_name={remote_user}",
            "-v", f"role_password='{password}'",
            "-f", "01_remote_setup.sql",
        ])

    print("==> Step 2/8: schema, role, types, tables (02_setup.sql)")
    run([
        "psql", central_conn, "-X", "-v", "ON_ERROR_STOP=1",
        "-v", f"instance_name_values={instance_name_values}",
        "-f", "02_setup.sql",
    ])

    print("==> Step 3/8: FDW procedure definition (03_fdw_setup.sql)")
    run_psql_file(central_conn, "03_fdw_setup.sql")

    print("==> Step 4/8: populating instance_config from config.yaml")
    insert_values = ",\n    ".join(instance_config_values(inst) for inst in instances)
    run_psql_command(
        central_conn,
        f"INSERT INTO stats_collect.instance_config ({INSTANCE_CONFIG_COLUMNS}) VALUES\n"
        f"    {insert_values};",
    )

    print("==> Step 5/8: one FOREIGN SERVER + USER MAPPING per instance")
    for inst in instances:
        name = inst["name"]
        cluster = inst["cluster"]
        remote_user = inst["remote_user"]
        password = password_for_cluster[cluster]
        print(f"    - {name} (cluster={cluster}, as {remote_user})")
        run_psql_command(
            central_conn,
            f"CALL stats_collect.setup_instance_fdw('{name}', '{password}');",
        )

    print("==> Step 6/8: collection procedure (04_collect_procedure.sql)")
    run_psql_file(central_conn, "04_collect_procedure.sql")

    print("==> Step 7/8: pg_cron schedule (05_schedule_pg_cron.sql)")
    print(
        "    (requires pg_cron already in shared_preload_libraries -- see "
        "that file's header; this script does not touch AWS infrastructure)"
    )
    run_psql_file(f"{central_conn} dbname=postgres", "05_schedule_pg_cron.sql")
    print(
        f"    scheduled job '{job_name}' -- verify with: "
        f'psql "{central_conn} dbname=postgres" -c "SELECT * FROM cron.job '
        f"WHERE jobname = '{job_name}';\""
    )

    print("==> Step 8/8: reports + delete_collection utility")
    run_psql_file(central_conn, "06_reports.sql", {"app_database": cfg["job"]["runs_in"]})
    run_psql_file(central_conn, "08_reports_ownership.sql", {"owner_role": owner_role})
    run_psql_file(central_conn, "07_delete_collection.sql")

    instances_for_cluster: dict[str, list[str]] = {}
    databases_for_cluster: dict[str, set[str]] = {}
    for inst in instances:
        cluster = inst["cluster"]
        instances_for_cluster.setdefault(cluster, []).append(inst["name"])
        databases_for_cluster.setdefault(cluster, set()).add(inst["database_name"])
    print_password_summary([
        (
            remote_user_for_cluster[cluster],
            password_for_cluster[cluster],
            ",".join(sorted(databases_for_cluster[cluster])),
            instances_for_cluster[cluster],
        )
        for cluster in password_for_cluster
    ])

    print()
    print("Deploy complete. Test with:")
    print(
        f'  psql "{central_conn}" -c "SET ROLE {owner_role}; '
        f'CALL {schema}.collect_stats(); RESET ROLE;"'
    )


if __name__ == "__main__":
    main()
