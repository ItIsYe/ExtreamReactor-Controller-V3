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
META_RE = re.compile(r'^\s*(manifest_id|manifest_version|hash_algo|source_ref)\s*=\s*(.+?),\s*$')


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_manifest(text: str):
    entries = []
    metadata = {}
    for line in text.splitlines():
        meta_match = META_RE.match(line)
        if meta_match:
            metadata[meta_match.group(1)] = meta_match.group(2).strip().strip('"')
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
    return entries, metadata


def index_entries(entries):
    indexed = {}
    for entry in entries:
        indexed[entry["path"]] = entry
    return indexed


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read()


def verify_remote(base_url: str, required_paths):
    root = base_url.rstrip("/") + "/"
    manifest_url = root + "manifest.lua"
    manifest_body = fetch(manifest_url)
    manifest_text = manifest_body.decode("utf-8")
    entries, metadata = parse_manifest(manifest_text)

    errors = []
    available_paths = {entry["path"] for entry in entries}
    for path in required_paths:
        if path not in available_paths:
            errors.append(f"required path missing from manifest: {path}")
    checked = 0
    for entry in entries:
        file_url = root + entry["path"]
        try:
            content = fetch(file_url)
        except urllib.error.URLError as exc:
            errors.append(f"download failed for {entry['path']} (url={file_url}): {exc}")
            continue

        actual_size = len(content)
        actual_hash = crc32_hex(content)
        if actual_size != entry["size_bytes"]:
            errors.append(
                f"size mismatch for {entry['path']} (url={file_url}): manifest={entry['size_bytes']} remote={actual_size}"
            )
        if actual_hash != entry["hash"]:
            errors.append(
                f"hash mismatch for {entry['path']} (url={file_url}): manifest={entry['hash']} remote={actual_hash}"
            )
        checked += 1

    return entries, metadata, checked, errors


def verify_local_manifest(expected_manifest: pathlib.Path):
    text = expected_manifest.read_text(encoding="utf-8")
    entries, _ = parse_manifest(text)
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
    return entries, errors


def verify_remote_manifest_matches_expected(remote_entries, remote_metadata, expected_manifest: pathlib.Path):
    expected_entries = parse_manifest(expected_manifest.read_text(encoding="utf-8"))
    expected_entries, expected_meta = expected_entries
    remote_index = index_entries(remote_entries)
    expected_index = index_entries(expected_entries)

    errors = []
    for rel, expected in expected_index.items():
        remote = remote_index.get(rel)
        if not remote:
            errors.append(f"remote manifest missing expected path: {rel}")
            continue
        if remote["size_bytes"] != expected["size_bytes"]:
            errors.append(
                f"remote manifest size mismatch for {rel}: expected-manifest={expected['size_bytes']} remote-manifest={remote['size_bytes']}"
            )
        if remote["hash"] != expected["hash"]:
            errors.append(
                f"remote manifest hash mismatch for {rel}: expected-manifest={expected['hash']} remote-manifest={remote['hash']}"
            )

    for rel in remote_index:
        if rel not in expected_index:
            errors.append(f"remote manifest has unexpected path not in expected manifest: {rel}")

    for key in ("manifest_id", "manifest_version", "hash_algo", "source_ref"):
        remote_value = str(remote_metadata.get(key, ""))
        expected_value = str(expected_meta.get(key, ""))
        if remote_value != expected_value:
            errors.append(
                f"remote manifest metadata mismatch for {key}: expected-manifest={expected_value} remote-manifest={remote_value}"
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
    parser.add_argument(
        "--require-path",
        action="append",
        default=[],
        help="Require that this relative path exists in the published manifest (repeatable)",
    )
    parser.add_argument(
        "--expected-manifest",
        help="Compare published manifest entries against this expected manifest file path",
    )
    args = parser.parse_args()

    if args.check_local:
        _, local_errors = verify_local_manifest(LOCAL_MANIFEST)
        if local_errors:
            print("Local manifest consistency: FAIL")
            for error in local_errors:
                print(f" - {error}")
            return 1
        print("Local manifest consistency: OK")

    try:
        remote_entries, remote_metadata, checked, errors = verify_remote(args.base_url, args.require_path)
    except Exception as exc:
        print(f"Remote verification failed: {exc}")
        return 1

    if args.expected_manifest:
        expected_manifest = pathlib.Path(args.expected_manifest)
        if not expected_manifest.is_absolute():
            expected_manifest = REPO_ROOT / expected_manifest
        if not expected_manifest.exists():
            print(f"Expected manifest file not found: {expected_manifest}")
            return 1
        expected_errors = verify_remote_manifest_matches_expected(remote_entries, remote_metadata, expected_manifest)
        if expected_errors:
            print("Remote vs expected manifest consistency: FAIL")
            for error in expected_errors:
                print(f" - {error}")
            return 1
        print("Remote vs expected manifest consistency: OK")

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
