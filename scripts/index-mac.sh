#!/bin/bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$EUID" != 0 ]] || die "Run on the Mac as the signed-in user."
scripts=$(cd "$(dirname "$0")" && pwd)
root="$HOME/.project-drive"
cluster="$root/postgres"
socket="$root/socket"
label="local.projectdrive.postgres"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
port=55432
pg=${PROJECT_DRIVE_PGBIN:-}
if [[ -z "$pg" ]] && command -v brew >/dev/null; then
    pg="$(brew --prefix postgresql@16)/bin"
fi
[[ -x "$pg/postgres" ]] || die "Install Homebrew postgresql@16, or set PROJECT_DRIVE_PGBIN."

export PGHOST="$socket" PGPORT="$port" PGUSER="$(id -un)"
unset PGDATABASE PGSERVICE PGPASSWORD PGOPTIONS PGHOSTADDR
psql=("$pg/psql" -X -w -v ON_ERROR_STOP=1)

start_index() {
    [[ -f "$cluster/PG_VERSION" && -f "$plist" ]] || die "Run index-mac.sh init first."
    if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl bootstrap "$domain" "$plist"
    fi
    for attempt in {1..20}; do
        "$pg/pg_isready" -d postgres -t 1 -q && return
        sleep 1
    done
    die "PostgreSQL did not start. See $root/postgres.log."
}

case "${1:-}" in
    init)
        mkdir -p "$root" "$socket" "$HOME/Library/LaunchAgents"
        chmod 700 "$root" "$socket"
        if [[ ! -f "$cluster/PG_VERSION" ]]; then
            "$pg/initdb" -D "$cluster" --auth-local=peer --auth-host=scram-sha-256 \
                --encoding=UTF8 --locale=C
        fi
        cp "$scripts/index-pg_hba.conf" "$cluster/pg_hba.conf"
        if [[ ! -f "$plist" ]]; then
            python3 - "$plist" "$label" "$pg/postgres" "$cluster" "$socket" "$port" "$root" <<'PY'
import plistlib
import sys

path, label, postgres, cluster, socket, port, root = sys.argv[1:]
with open(path, "xb") as stream:
    plistlib.dump({
        "Label": label, "RunAtLoad": True, "KeepAlive": True,
        "ProgramArguments": [
            postgres, "-D", cluster, "-h", "127.0.0.1", "-p", port, "-k", socket,
            "-c", "password_encryption=scram-sha-256",
        ],
        "StandardOutPath": root + "/postgres.log", "StandardErrorPath": root + "/postgres.log",
    }, stream)
PY
        fi
        start_index
        "$pg/pg_ctl" -D "$cluster" reload
        "${psql[@]}" -d postgres -f "$scripts/index-roles.sql"
        printf '%s\n' "Set separate passwords with index-mac.sh password mac and password windows."
        ;;
    start) start_index ;;
    stop) launchctl bootout "$domain/$label" ;;
    status)
        "$pg/pg_isready" -d postgres
        "${psql[@]}" -d postgres -Atc "SHOW listen_addresses; SHOW port;"
        ;;
    password|revoke)
        case "${2:-}" in
            mac|windows) role="projectdrive_$2" ;;
            *) die "Specify mac or windows." ;;
        esac
        if [[ "$1" == password ]]; then
            "${psql[@]}" -d postgres -c "\password $role"
            "${psql[@]}" -d postgres -c "ALTER ROLE $role LOGIN"
        else
            "${psql[@]}" -d postgres -c "ALTER ROLE $role NOLOGIN" \
                -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename='$role'"
        fi
        ;;
    dump)
        output=${2:?Pass a new backup filename ending in .dump.}
        [[ ! -e "$output" && ! -L "$output" ]] || die "The backup filename already exists."
        partial=$(mktemp "$output.partial.XXXXXX")
        trap 'rm -f "$partial"' EXIT
        "$pg/pg_dump" -w -Fc -f "$partial" projectdrive
        "$pg/pg_restore" --list "$partial" >/dev/null
        (set -o noclobber; cat "$partial" > "$output")
        ;;
    restore-test)
        archive=${2:?Pass the PostgreSQL dump to verify.}
        target=${3:?Pass a fresh scratch database name.}
        [[ "$target" =~ ^projectdrive_restore_[a-z0-9_]{1,35}$ ]] || die "Use projectdrive_restore_<suffix>."
        "$pg/pg_restore" --list "$archive" >/dev/null
        "$pg/createdb" -w --owner projectdrive_owner "$target"
        "${psql[@]}" -d postgres -c "REVOKE ALL ON DATABASE $target FROM PUBLIC"
        "$pg/pg_restore" -w --exit-on-error --single-transaction --no-owner --no-privileges \
            --role=projectdrive_owner --dbname="$target" "$archive"
        "${psql[@]}" -d "$target" -c "SELECT count(*) AS restored_tables FROM pg_tables WHERE schemaname='public'"
        ;;
    *) die "Usage: index-mac.sh init|start|stop|status|password <device>|revoke <device>|dump <file>|restore-test <file> <db>" ;;
esac
