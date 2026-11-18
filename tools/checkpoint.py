"""Create, verify, and restore independent copies of selected native files and index exports."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile


CHUNK = 8 * 1024 * 1024


def ordinary(path, directory=False):
    info = path.lstat()
    check_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not check_type(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError(f"Expected an ordinary {'directory' if directory else 'file'} at {path}")
    return info


def digest(path, copy_to=None):
    ordinary(path)
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        if copy_to is None:
            for block in iter(lambda: source.read(CHUNK), b""):
                checksum.update(block)
        else:
            with copy_to.open("xb") as target:
                for block in iter(lambda: source.read(CHUNK), b""):
                    checksum.update(block)
                    target.write(block)
                target.flush()
                os.fsync(target.fileno())
    return checksum.hexdigest()


def signature(info):
    return info.st_size, info.st_mtime_ns


def safe_entry(root, name):
    parts = PurePosixPath(name).parts
    if (len(parts) < 2 or parts[0] not in ("files", "index")
            or any(part in ("..", ".") or ":" in part or "\\" in part for part in parts)
            or PurePosixPath(name).as_posix() != name):
        raise ValueError(f"Invalid path in checkpoint: {name}")
    result = root.joinpath(*parts)
    for parent in result.parents:
        if parent == root:
            break
        if parent.exists() or parent.is_symlink():
            ordinary(parent, directory=True)
    return result


def read_manifest(root):
    ordinary(root, directory=True)
    path = root / "manifest.json"
    ordinary(path)
    manifest = json.loads(path.read_bytes())
    if manifest.get("version") != 1 or not manifest.get("entries"):
        raise ValueError("The checkpoint manifest is empty or unsupported.")
    return manifest


def capture_file(source, destination, prior_file=None, prior_entry=None):
    info = ordinary(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if prior_entry and signature(info) == (prior_entry["bytes"], prior_entry["mtime_ns"]):
        expected = digest(prior_file, destination)
        if expected != prior_entry["sha256"]:
            raise ValueError(f"The previous checkpoint has a corrupt copy of {source}.")
        reused = True
    else:
        expected = digest(source, destination)
        reused = False
    if signature(ordinary(source)) != signature(info):
        raise ValueError(f"{source} changed during capture. Close editors and retry.")
    os.utime(destination, ns=(info.st_atime_ns, info.st_mtime_ns))
    if digest(destination) != expected:
        raise ValueError(f"The copied bytes failed verification for {source}.")
    return {"bytes": info.st_size, "mtime_ns": info.st_mtime_ns, "sha256": expected}, reused


def raise_walk_error(error):
    raise error


def create(args):
    ordinary(args.source, directory=True)
    ordinary(args.root, directory=True)
    source = args.source.resolve(strict=True)
    root = args.root.resolve(strict=True)
    if source == root or source.is_relative_to(root) or root.is_relative_to(source):
        raise ValueError("Choose a backup root outside the source tree on the independent disk.")
    previous = args.previous.resolve(strict=True) if args.previous else None
    if previous and previous.parent != root:
        raise ValueError("The previous checkpoint must be directly under the same backup root.")
    manifest = read_manifest(previous) if previous else None
    if manifest and manifest["source"] != str(source):
        raise ValueError("The previous checkpoint belongs to a different source.")
    previous_entries = manifest["entries"] if manifest else {}

    created = dt.datetime.now(dt.timezone.utc)
    final = root / created.strftime("checkpoint-%Y%m%dT%H%M%S%fZ")
    entries = {}
    directory_names = []
    reused_count = 0
    with tempfile.TemporaryDirectory(prefix=".project-drive-", dir=root) as temp_dir:
        staging = Path(temp_dir) / "snapshot"
        (staging / "files").mkdir(parents=True)
        for folder, directories, files in os.walk(source, onerror=raise_walk_error):
            for directory in directories:
                path = Path(folder) / directory
                ordinary(path, directory=True)
                name = (Path("files") / path.relative_to(source)).as_posix()
                safe_entry(staging, name).mkdir()
                directory_names.append(name)
            for file in files:
                item = Path(folder) / file
                name = (Path("files") / item.relative_to(source)).as_posix()
                prior = safe_entry(previous, name) if name in previous_entries else None
                entry, reused = capture_file(item, safe_entry(staging, name), prior,
                                             previous_entries.get(name))
                entries[name] = entry
                reused_count += reused
        if not entries:
            raise ValueError("The selected source is empty. Check that the drive is mounted.")
        for item in args.index_file:
            name = f"index/{item.name}"
            if name in entries:
                raise ValueError(f"Duplicate index export name: {item.name}")
            entries[name], _ = capture_file(item, safe_entry(staging, name))
        with (staging / "manifest.json").open("x", encoding="utf-8") as stream:
            json.dump({"version": 1, "created": created.isoformat(), "source": str(source),
                       "entries": entries, "directories": sorted(directory_names)},
                      stream, indent=2, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        staging.rename(final)
    print(f"{final} ({len(entries)} files verified, {reused_count} reused from the backup disk)")


def verify_or_restore(args):
    root = args.checkpoint.resolve(strict=True)
    manifest = read_manifest(root)
    entries = manifest["entries"]
    directories = manifest.get("directories", [])
    if args.action == "verify":
        for name in directories:
            ordinary(safe_entry(root, name), directory=True)
        for name, entry in entries.items():
            if digest(safe_entry(root, name)) != entry["sha256"]:
                raise ValueError(f"Checksum mismatch for {name}.")
        print(f"Verified {len(entries)} files.")
        return

    if args.file:
        entries = {args.file: entries[args.file]}
    original = args.to
    if original.exists() or original.is_symlink():
        raise ValueError("Choose a new restore directory.")
    parent = original.parent.resolve(strict=True)
    destination = parent / original.name
    if destination.is_relative_to(root):
        raise ValueError("Restore outside the checkpoint.")
    with tempfile.TemporaryDirectory(prefix=".project-drive-restore-", dir=parent) as temp_dir:
        staging = Path(temp_dir) / "restored"
        staging.mkdir()
        if not args.file:
            for name in directories:
                safe_entry(staging, name).mkdir(parents=True, exist_ok=True)
        for name, entry in entries.items():
            src = safe_entry(root, name)
            target = safe_entry(staging, name)
            copied, _ = capture_file(src, target)
            if copied["sha256"] != entry["sha256"]:
                raise ValueError(f"Checksum mismatch for {name}.")
            os.utime(target, ns=(entry["mtime_ns"], entry["mtime_ns"]))
        if destination.exists() or destination.is_symlink():
            raise ValueError("The restore directory appeared during the copy.")
        staging.rename(destination)
    print(f"Restored and verified {len(entries)} files under {destination}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    capture = commands.add_parser("create")
    capture.add_argument("--source", type=Path, required=True)
    capture.add_argument("--root", type=Path, required=True)
    capture.add_argument("--previous", type=Path)
    capture.add_argument("--index-file", type=Path, action="append", default=[])
    commands.add_parser("verify").add_argument("--checkpoint", type=Path, required=True)
    restore = commands.add_parser("restore")
    restore.add_argument("--checkpoint", type=Path, required=True)
    restore.add_argument("--to", type=Path, required=True)
    restore.add_argument("--file", help="One path from the checkpoint, such as files/Assets/example.bin.")
    args = parser.parse_args()
    try:
        if args.action == "create":
            create(args)
        else:
            verify_or_restore(args)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Checkpoint: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
