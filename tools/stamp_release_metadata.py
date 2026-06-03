#!/usr/bin/env python3
"""Stamp xreactor/release.lua for a concrete release build.

This helper is intentionally not used for normal moving beta-branch installs.
For a release build, run it from the repository root with a concrete commit SHA:

    python3 tools/stamp_release_metadata.py --commit-sha <sha> --release-id <id>

It updates release.lua with:
- release_id
- commit_sha
- source_ref
- manifest_id / manifest_version from xreactor/manifest.lua
- manifest_file_count from manifest entries
- installer_core metadata for the root installer file

The script does not commit changes. Commit the resulting release.lua as part of the
release/stamping workflow.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"
RELEASE_PATH = XREACTOR_ROOT / "release.lua"
INSTALLER_PATH = REPO_ROOT / "installer"

ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"([^"]+)"')
MANIFEST_VERSION_RE = re.compile(r'manifest_version\s*=\s*(\d+)')
MANIFEST_ID_RE = re.compile(r'manifest_id\s*=\s*"([^"]+)"')
HASH_ALGO_RE = re.compile(r'hash_algo\s*=\s*"([^"]+)"')


def crc32_hex(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"


def parse_manifest_metadata() -> dict[str, object]:
    text = MANIFEST_PATH.read_text(encoding="utf-8")
    version_match = MANIFEST_VERSION_RE.search(text)
    id_match = MANIFEST_ID_RE.search(text)
    hash_match = HASH_ALGO_RE.search(text)
    entries = ENTRY_RE.findall(text)
    if not version_match or not id_match:
        raise SystemExit("manifest.lua is missing manifest_version or manifest_id")
    return {
        "manifest_version": int(version_match.group(1)),
        "manifest_id": id_match.group(1),
        "hash_algo": hash_match.group(1) if hash_match else "crc32",
        "manifest_file_count": len(entries),
    }


def installer_metadata() -> dict[str, object]:
    if not INSTALLER_PATH.exists():
        return {"installer_core_hash": "missing", "installer_core_size_bytes": 0}
    data = INSTALLER_PATH.read_bytes()
    return {
        "installer_core_hash": crc32_hex(data),
        "installer_core_size_bytes": len(data),
    }


def render_release(args: argparse.Namespace, manifest: dict[str, object], installer: dict[str, object]) -> str:
    source_ref = args.source_ref or args.commit_sha
    return (
        "return {\n"
        f'  release_id = "{args.release_id}",\n'
        f'  commit_sha = "{args.commit_sha}",\n'
        f'  source_ref = "{source_ref}",\n'
        f'  manifest_id = "{manifest["manifest_id"]}",\n'
        f'  manifest_version = {manifest["manifest_version"]},\n'
        f'  manifest_file_count = {manifest["manifest_file_count"]},\n'
        f'  hash_algo = "{manifest["hash_algo"]}",\n'
        '  manifest_path = "xreactor/manifest.lua",\n'
        f'  installer_core_version = "{args.installer_core_version}",\n'
        f'  installer_core_hash = "{installer["installer_core_hash"]}",\n'
        f'  installer_core_size_bytes = {installer["installer_core_size_bytes"]},\n'
        "}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Stamp xreactor/release.lua for a concrete release build")
    parser.add_argument("--commit-sha", required=True, help="Concrete commit SHA to stamp into release.lua")
    parser.add_argument("--release-id", required=True, help="Release identifier, for example v3.0.0 or beta-v24-<sha>")
    parser.add_argument("--source-ref", default=None, help="Optional source ref to use instead of commit SHA")
    parser.add_argument("--installer-core-version", default="2.0")
    args = parser.parse_args()

    manifest = parse_manifest_metadata()
    installer = installer_metadata()
    RELEASE_PATH.write_text(render_release(args, manifest, installer), encoding="utf-8")
    print(f"stamped {RELEASE_PATH.relative_to(REPO_ROOT)} for {args.release_id} @ {args.commit_sha}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
