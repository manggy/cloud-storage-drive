#!/bin/bash
set -euo pipefail
umask 077

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$EUID" != 0 ]] || die "Run on the Mac as the signed-in user."
scripts=$(cd "$(dirname "$0")" && pwd)
config=${PROJECT_DRIVE_CONFIG:-"$scripts/../config/mac.local.json"}
root="$HOME/.project-drive"
mountpoint="$HOME/Cloud Storage"
cache_volume="/Volumes/ProjectDriveCache"
cache="$cache_volume/cache"
command -v juicefs >/dev/null || die "Install the official JuiceFS client on PATH."

mount_entry() { /sbin/mount | grep -F " on $mountpoint (" || true; }

require_our_mount() {
    [[ "$(mount_entry)" == *project-drive* ]] ||
        die "No project-drive mount identified at $mountpoint. Check the mount listing."
}

case "${1:-}" in
    unmount)
        require_our_mount
        juicefs umount "$mountpoint"
        exit
        ;;
    mount|mount-readonly|status|initialize|grow|dump) ;;
    *) die "Usage: client-mac.sh mount|mount-readonly|status|unmount|initialize|grow|dump <file>" ;;
esac

cloud="$scripts/../tools/cloud.py"
settings=$(python3 "$cloud" client-settings --config "$config" --device mac)
IFS=$'\t' read -r profile role bucket host region bucket_name <<< "$settings"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
    AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
    ACCESS_KEY SECRET_KEY SESSION_TOKEN META_PASSWORD META_PASSWORD_FILE
export AWS_PROFILE="$profile" AWS_DEFAULT_PROFILE="$profile"
export AWS_REGION="$region" AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true
export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true

uri="postgres://projectdrive_mac@$host:55432/projectdrive?sslmode=disable&connect_timeout=5"
entry=$(mount_entry)
if [[ -n "$entry" && "$entry" != *project-drive* ]]; then
    die "Another filesystem is mounted at $mountpoint."
fi
if [[ "$1" == status ]]; then
    printf 'Finder mount: %s\n' "${entry:-disconnected}"
fi
if [[ "$host" == 127.0.0.1 && ("$1" == mount* || "$1" == initialize) ]]; then
    bash "$scripts/index-mac.sh" start
fi
if ! /usr/bin/nc -z -G 5 "$host" 55432; then
    die "Index unavailable at $host:55432. Check host wake state, PostgreSQL and Tailscale."
fi
python3 "$cloud" check-mount --config "$config" --device mac

# The Keychain item's account is the index host, so moving the index can use a new password.
if ! META_PASSWORD=$(security find-generic-password -a "$host" -s "ProjectDrive PostgreSQL" -w 2>/dev/null); then
    read -rs -p "PostgreSQL password for projectdrive_mac: " META_PASSWORD
    printf '\n' >&2
fi
[[ -n "$META_PASSWORD" ]] || die "An index password is required."
export META_PASSWORD

case "$1" in
    initialize)
        juicefs format --no-update --storage s3 --bucket "$bucket" --capacity 25 \
            --trash-days 1 "$uri" project-drive
        ;;
    mount|mount-readonly)
        if [[ -n "$entry" ]]; then
            [[ "$1" == mount ]] || die "Unmount the existing drive before opening it read-only."
            printf '%s\n' "Already mounted. If Finder is stale, close editors and run unmount before reconnecting."
        else
            python3 - "$cache_volume" <<'PY'
import plistlib
import subprocess
import sys

path = sys.argv[1]
def diskutil(*args):
    return plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", *args]))

try:
    info = diskutil("info", "-plist", path)
    volumes = diskutil("apfs", "list", "-plist")["Containers"]
    volume = next(v for c in volumes for v in c["Volumes"]
                  if v["DeviceIdentifier"] == info["DeviceIdentifier"])
except (KeyError, StopIteration, subprocess.CalledProcessError):
    sys.exit("Mount the dedicated ProjectDriveCache APFS volume first.")
if (info.get("MountPoint") != path or volume.get("FileVault") is not True
        or volume.get("Locked") or volume.get("CryptoMigrationOn")
        or volume.get("CapacityReserve") != 0
        or not 1024 ** 3 < volume.get("CapacityQuota", 0) <= 2 * 1024 ** 3):
    sys.exit("ProjectDriveCache must be unlocked and encrypted, with a quota above 1 GiB "
             "and at most 2 GiB, and no reserve.")
if info.get("GlobalPermissionsEnabled") is False:
    sys.exit("Enable ownership on ProjectDriveCache before mounting.")
PY
            [[ ! -L "$mountpoint" && ! -L "$cache" ]] || die "Mount and cache paths must be ordinary directories."
            mkdir -p "$mountpoint" "$cache" "$root"
            [[ -O "$cache" && -z "$(ls -A "$mountpoint")" ]] ||
                die "Use your own cache directory and an empty Finder mountpoint."
            chmod 700 "$cache" "$root"
            flags=()
            if [[ "$1" == mount-readonly ]]; then
                flags=(--read-only --no-bgjob)
            fi
            juicefs mount -d -o backend=fskit,fsname=project-drive --cache-dir "$cache" --cache-size 1024 \
                --backup-meta 0 --metrics 127.0.0.1:0 --no-usage-report \
                --log "$root/juicefs.log" ${flags[@]+"${flags[@]}"} "$uri" "$mountpoint"
        fi
        open "$mountpoint"
        ;;
    status)
        juicefs status --session 0 "$uri"
        ;;
    grow)
        [[ "${2:-}" == "100-after-acceptance" ]] ||
            die "After the recovery and app tests pass, run grow 100-after-acceptance."
        juicefs config --capacity 100 "$uri"
        ;;
    dump)
        file=${2:?Pass a new backup filename ending in .json.}
        [[ ! -e "$file" && ! -L "$file" ]] || die "The backup filename already exists."
        partial=$(mktemp -d "${file}.partial.XXXXXX")
        trap 'rm -f "$partial/metadata.json"; rmdir "$partial"' EXIT
        juicefs dump "$uri" "$partial/metadata.json"
        python3 - "$partial/metadata.json" "$file" <<'PY'
import json
from pathlib import Path
import shutil
import sys

source, target = map(Path, sys.argv[1:])
settings = json.loads(source.read_bytes())["Setting"]
if any(settings.get(key) for key in ("AccessKey", "SecretKey", "SessionToken")):
    sys.exit("The export contains storage credentials and could not be published.")
with source.open("rb") as inp, target.open("xb") as out:
    shutil.copyfileobj(inp, out)
PY
        ;;
esac
