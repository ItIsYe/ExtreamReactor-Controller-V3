#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys
import urllib.error
import urllib.request
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCAL_MANIFEST = REPO_ROOT / "xreactor" / "manifest.lua"
ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)",\s*size_bytes\s*=\s*(?P<size>\d+),\s*hash\s*=\s*"(?P<hash>[0-9a-f]+)"')


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_manifest(text: str):
    entries = []
    for line in text.splitlines():
        m = ENTRY_RE.search(line)
        if not m:
            continue
        entries.append(
            {
                "path": m.group("path"),
                "size_bytes": int(m.group("size")),
                "hash": m.group("hash"),
            }
        )
    if not entries:
        raise RuntimeError("manifest contains no file entries")
    return entries


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()


def verify_remote(base_url: str):
    root = base_url.rstrip("/") + "/"
    manifest_url = root + "manifest.lua"
    manifest_body = fetch(manifest_url)
    manifest_text = manifest_body.decode("utf-8")
    entries = parse_manifest(manifest_text)

    errors = []
    checked = 0
    for entry in entries:
        file_url = root + entry["path"]
        try:
            content = fetch(file_url)
        except urllib.error.URLError as exc:
            errors.append(f"download failed for {entry['path']}: {exc}")
            continue

        actual_size = len(content)
        actual_hash = crc32_hex(content)
        if actual_size != entry["size_bytes"]:
            errors.append(
                f"size mismatch for {entry['path']}: manifest={entry['size_bytes']} remote={actual_size}"
            )
        if actual_hash != entry["hash"]:
            errors.append(
                f"hash mismatch for {entry['path']}: manifest={entry['hash']} remote={actual_hash}"
            )
        checked += 1

    return checked, errors


def verify_local_manifest(expected_manifest: pathlib.Path):
    text = expected_manifest.read_text(encoding="utf-8")
    entries = parse_manifest(text)
    errors = []
    for entry in entries:
        path = REPO_ROOT / "xreactor" / entry["path"]
        if not path.exists():
            errors.append(f"local file missing: {entry['path']}")
            continue
        data = path.read_bytes()
        if len(data) != entry["size_bytes"]:
            errors.append(
                f"local size mismatch for {entry['path']}: manifest={entry['size_bytes']} local={len(data)}"
            )
        local_hash = crc32_hex(data)
        if local_hash != entry["hash"]:
            errors.append(
                f"local hash mismatch for {entry['path']}: manifest={entry['hash']} local={local_hash}"
            )
    return errors


def main():
    parser = argparse.ArgumentParser(description="Verify published xreactor files against published manifest")
    parser.add_argument("--base-url", required=True, help="Published xreactor base URL ending at /xreactor")
    parser.add_argument(
        "--check-local",
        action="store_true",
        help="Also verify local repo xreactor files against local manifest before remote verification",
    )
    args = parser.parse_args()

    if args.check_local:
        local_errors = verify_local_manifest(LOCAL_MANIFEST)
        if local_errors:
            print("Local manifest consistency: FAIL")
            for error in local_errors:
                print(f" - {error}")
            return 1
        print("Local manifest consistency: OK")

    try:
        checked, errors = verify_remote(args.base_url)
    except Exception as exc:
        print(f"Remote verification failed: {exc}")
        return 1

    print(f"Remote files checked: {checked}")
    if errors:
        print("Remote manifest consistency: FAIL")
        for error in errors:
            print(f" - {error}")
        return 1

    print("Remote manifest consistency: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
