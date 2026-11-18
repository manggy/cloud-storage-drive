"""Record listing and range-read timings on disposable Project Drive fixtures."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time


SAMPLE = 4 * 1024 * 1024
NAME = "project-drive-probe.bin"


def read_edges(stream, size):
    length = min(SAMPLE, size)
    stream.seek(0)
    head = stream.read(length)
    stream.seek(size - length)
    tail = stream.read(length)
    if len(head) != length or len(tail) != length:
        raise OSError("A range read returned fewer bytes than expected.")
    return {
        "bytes": size, "range_bytes": length, "first_sha256": hashlib.sha256(head).hexdigest(),
        "last_sha256": hashlib.sha256(tail).hexdigest(),
    }


def inspect(path, full=False):
    with path.open("rb") as stream:
        measured = read_edges(stream, os.fstat(stream.fileno()).st_size)
        if full:
            stream.seek(0)
            checksum = hashlib.sha256()
            for block in iter(lambda: stream.read(SAMPLE), b""):
                checksum.update(block)
            measured["full_sha256"] = checksum.hexdigest()
        return measured


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    create = sub.add_parser("create")
    create.add_argument("--bytes", type=int, required=True)
    check = sub.add_parser("read")
    check.add_argument("--expected", type=Path, help="JSON from the create or read step.")
    check.add_argument("--full", action="store_true", help="Download and verify the whole fixture.")
    for command in (create, check):
        command.add_argument("directory", type=Path, help="An existing disposable project directory.")
    args = parser.parse_args()
    fixture = args.directory / NAME
    try:
        result = {}
        if args.action == "create":
            if args.bytes <= 0:
                raise ValueError("Fixture size must be positive.")
            started = time.monotonic()
            checksum = hashlib.sha256()
            with fixture.open("xb") as stream:
                remaining = args.bytes
                while remaining:
                    block = os.urandom(min(SAMPLE, remaining))
                    stream.write(block)
                    checksum.update(block)
                    remaining -= len(block)
                stream.flush()
                os.fsync(stream.fileno())
            result.update(inspect(fixture), full_sha256=checksum.hexdigest(),
                          write_and_probe_seconds=round(time.monotonic() - started, 3))
        else:
            started = time.monotonic()
            result["directory_entries"] = sum(1 for _ in args.directory.iterdir())
            result["list_seconds"] = round(time.monotonic() - started, 3)
            expected = json.loads(args.expected.read_bytes()) if args.expected else {}
            for label in ("first", "repeat"):
                started = time.monotonic()
                measured = inspect(fixture)
                result[f"{label}_read_seconds"] = round(time.monotonic() - started, 3)
                if result.get("first_sha256", measured["first_sha256"]) != measured["first_sha256"] or (
                    result.get("last_sha256", measured["last_sha256"]) != measured["last_sha256"]
                ):
                    raise ValueError("Range contents changed between reads.")
                result.update(measured)
            if args.full:
                started = time.monotonic()
                result.update(inspect(fixture, full=True))
                result["full_read_seconds"] = round(time.monotonic() - started, 3)
            compared = ["bytes", "first_sha256", "last_sha256"]
            if args.full:
                compared.append("full_sha256")
            if expected and any(result[key] != expected.get(key) for key in compared):
                raise ValueError("The fixture does not match the recorded checksums.")
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, KeyError) as exc:
        print(f"Project Drive probe: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
