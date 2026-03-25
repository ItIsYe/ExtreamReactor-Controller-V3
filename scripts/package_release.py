#!/usr/bin/env python3
import argparse
import pathlib
import re
import subprocess
import sys
import zipfile
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE_PATH = REPO_ROOT / "xreactor" / "release.lua"
INSTALLER_PATH = REPO_ROOT / "installer"


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_release(path: pathlib.Path):
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*([a-zA-Z0-9_]+)\s*=\s*(.+?),\s*$", line)
        if m:
            data[m.group(1)] = m.group(2)
    return data


def sync_release_metadata(write: bool):
    release = parse_release(RELEASE_PATH)
    installer = INSTALLER_PATH.read_bytes()
    expected_hash = crc32_hex(installer)
    expected_size = len(installer)

    hash_ok = release.get("installer_core_hash", '""').strip('"') == expected_hash
    size_ok = int(release.get("installer_core_size_bytes", "0")) == expected_size

    if hash_ok and size_ok:
        return True

    if not write:
        return False

    lines = RELEASE_PATH.read_text(encoding="utf-8").splitlines()
    out = []
    for line in lines:
        if re.match(r"\s*installer_core_hash\s*=", line):
            out.append(f'  installer_core_hash = "{expected_hash}",')
        elif re.match(r"\s*installer_core_size_bytes\s*=", line):
            out.append(f"  installer_core_size_bytes = {expected_size}")
        else:
            out.append(line)
    RELEASE_PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
    return True


def run_manifest_sync(write: bool):
    cmd = [sys.executable, str(REPO_ROOT / "scripts" / "manifest_sync.py")]
    if write:
        cmd.append("--write")
    subprocess.run(cmd, cwd=REPO_ROOT, check=True)


def build_zip(output_zip: pathlib.Path):
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.write(INSTALLER_PATH, arcname="installer")
        for path in sorted((REPO_ROOT / "xreactor").rglob("*")):
            if path.is_file():
                zf.write(path, arcname=str(path.relative_to(REPO_ROOT)))


def main():
    parser = argparse.ArgumentParser(description="Create consistent release package from repo state")
    parser.add_argument("--output", default="dist/xreactor-release.zip", help="zip output path")
    parser.add_argument("--sync", action="store_true", help="sync manifest/release metadata before packaging")
    args = parser.parse_args()

    run_manifest_sync(write=args.sync)

    if not sync_release_metadata(write=args.sync):
        print("release.lua installer metadata mismatch (use --sync)")
        return 1

    output_zip = REPO_ROOT / args.output
    build_zip(output_zip)
    print(f"Package: {output_zip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
