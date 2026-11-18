#!/bin/bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$EUID" == 0 && "$(uname -s)" == Linux ]] || die "Run with sudo on the Lightsail Ubuntu index host."
scripts=$(cd "$(dirname "$0")" && pwd)
disk_root=/srv/project-drive
conf=/etc/project-drive
pg=/usr/lib/postgresql/16/bin
port=55432
unit=projectdrive-index
socket=/run/projectdrive-index
unset PGHOST PGPORT PGUSER PGDATABASE PGSERVICE PGPASSWORD PGOPTIONS PGHOSTADDR
psql=(runuser -u postgres -- "$pg/psql" -X -w -h "$socket" -p "$port" -v ON_ERROR_STOP=1)

case "${1:-}" in
    prepare-disk)
        device=${2:?Pass the exact device identified as the 8 GiB attached Lightsail data disk.}
        [[ -b "$device" && "$device" == /dev/* ]] || die "Choose the attached block device under /dev."
        device=$(readlink -f "$device")
        [[ "$(lsblk -dnro TYPE "$device")" == disk && "$(blockdev --getsize64 "$device")" == 8589934592 ]] ||
            die "The device must be the 8 GiB whole data disk."
        [[ "$(lsblk -nro TYPE "$device")" == disk ]] || die "The device has child partitions or logical volumes."
        mkdir -p "$disk_root"
        filesystem=$(blkid -o value -s TYPE "$device" || true)
        if [[ -z "$filesystem" ]]; then
            [[ "${3:-}" == "--format-empty-disk" && -z "$(wipefs --noheadings --output TYPE "$device")" &&
                -z "$(lsblk -nro MOUNTPOINT "$device")" ]] || die "Formatting needs the empty-disk flag and a blank, unmounted disk."
            mkfs.ext4 -L ProjectDriveIndex "$device"
        elif [[ "$filesystem" != ext4 || "$(blkid -o value -s LABEL "$device")" != ProjectDriveIndex ]]; then
            die "The disk has a filesystem that was not prepared for Project Drive."
        fi
        uuid=$(blkid -o value -s UUID "$device")
        if findmnt -rn -M "$disk_root" >/dev/null; then
            [[ "$(findmnt -n -o UUID -M "$disk_root")" == "$uuid" ]] || die "A different filesystem is mounted."
            exit
        fi
        mounted=$(lsblk -nro MOUNTPOINT "$device")
        [[ -z "$mounted" && -z "$(ls -A "$disk_root")" ]] || die "The disk or mount directory is in use."
        if ! grep -Fq "UUID=$uuid $disk_root " /etc/fstab; then
            if grep -Eq "[[:space:]]$disk_root[[:space:]]" /etc/fstab; then
                die "Review the existing mount entry in /etc/fstab."
            fi
            printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$disk_root" >> /etc/fstab
        fi
        systemctl daemon-reload
        mount "$disk_root"
        ;;
    init)
        [[ -x "$pg/postgres" ]] || die "Install the Ubuntu postgresql-16 package first."
        [[ "$(findmnt -n -o LABEL -M "$disk_root")" == ProjectDriveIndex ]] || die "Mount the data disk first."
        if [[ ! -f "$disk_root/postgres/PG_VERSION" ]]; then
            install -o postgres -g postgres -m 0700 -d "$disk_root/postgres"
            runuser -u postgres -- "$pg/initdb" -D "$disk_root/postgres" \
                --auth-local=peer --auth-host=scram-sha-256 --encoding=UTF8 --locale=C
        fi
        [[ "$(cat "$disk_root/postgres/PG_VERSION")" == 16 ]] || die "The data disk requires PostgreSQL 16."
        install -d -m 0755 "$conf"
        install -o postgres -g postgres -m 0640 "$scripts/index-pg_hba.conf" "$conf/pg_hba.conf"
        cat > "/etc/systemd/system/$unit.service" <<'UNIT'
[Unit]
Description=Project Drive PostgreSQL index
RequiresMountsFor=/srv/project-drive
ConditionPathIsMountPoint=/srv/project-drive

[Service]
User=postgres
Group=postgres
RuntimeDirectory=projectdrive-index
RuntimeDirectoryMode=0700
ExecStart=/usr/lib/postgresql/16/bin/postgres -D /srv/project-drive/postgres -h 127.0.0.1 -p 55432 -k /run/projectdrive-index -c hba_file=/etc/project-drive/pg_hba.conf -c password_encryption=scram-sha-256 -c shared_buffers=64MB -c max_connections=40
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed
KillSignal=SIGINT
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
        chmod 0644 "/etc/systemd/system/$unit.service"
        systemctl daemon-reload
        systemctl enable --now "$unit"
        for attempt in {1..20}; do
            runuser -u postgres -- "$pg/pg_isready" -h "$socket" -p "$port" -d postgres -t 1 -q && break
            sleep 1
        done
        systemctl reload "$unit"
        "${psql[@]}" -d postgres -f "$scripts/index-roles.sql"
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
    restore)
        file=${2:?Pass the PostgreSQL dump from the stopped original index.}
        [[ "$("${psql[@]}" -d projectdrive -Atc "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" == 0 ]] ||
            die "The hosted database has existing tables. Restore requires a fresh database."
        "$pg/pg_restore" --list "$file" >/dev/null
        runuser -u postgres -- "$pg/pg_restore" -w -h "$socket" -p "$port" --exit-on-error --single-transaction \
            --no-owner --no-privileges --role=projectdrive_owner --dbname=projectdrive < "$file"
        ;;
    dump)
        file=${2:?Pass a new backup filename ending in .dump.}
        [[ ! -e "$file" && ! -L "$file" ]] || die "The backup filename already exists."
        partial=$(mktemp "$file.partial.XXXXXX")
        trap 'rm -f "$partial"' EXIT
        runuser -u postgres -- "$pg/pg_dump" -w -h "$socket" -p "$port" -Fc projectdrive > "$partial"
        "$pg/pg_restore" --list "$partial" >/dev/null
        (set -o noclobber; cat "$partial" > "$file")
        ;;
    *) die "Usage: hosted-index.sh prepare-disk <device> [--format-empty-disk]|init|password <device>|revoke <device>|restore <dump>|dump <file>" ;;
esac
