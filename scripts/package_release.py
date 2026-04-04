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
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_release(path: pathlib.Path):
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*([a-zA-Z0-9_]+)\s*=\s*(.+?),\s*$", line)
        if m:
            data[m.group(1)] = m.group(2)
    return data


def parse_manifest_metadata(path: pathlib.Path):
    data = {}
    file_count = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        entry_match = re.search(r'\bpath\s*=\s*"([^"]+)"', line)
        if entry_match:
            file_count += 1
        kv = re.match(r"\s*(manifest_id|manifest_version|hash_algo)\s*=\s*(.+?),\s*$", line)
        if kv:
            data[kv.group(1)] = kv.group(2)
    data["manifest_file_count"] = str(file_count)
    data["manifest_path"] = '"xreactor/manifest.lua"'
    return data


def sync_release_metadata(write: bool):
    release = parse_release(RELEASE_PATH)
    manifest = parse_manifest_metadata(MANIFEST_PATH)
    installer = INSTALLER_PATH.read_bytes()
    expected_hash = crc32_hex(installer)
    expected_size = len(installer)

    expected = {
        "installer_core_hash": f'"{expected_hash}"',
        "installer_core_size_bytes": str(expected_size),
        "manifest_id": manifest.get("manifest_id", '"manifest-v6"'),
        "manifest_version": manifest.get("manifest_version", "6"),
        "manifest_file_count": manifest.get("manifest_file_count", "0"),
        "hash_algo": manifest.get("hash_algo", '"crc32"'),
        "manifest_path": manifest.get("manifest_path", '"xreactor/manifest.lua"'),
    }

    mismatches = {}
    for key, expected_value in expected.items():
        actual_value = release.get(key)
        if actual_value is None:
            mismatches[key] = {"actual": "<missing>", "expected": expected_value}
            continue
        if key in ("installer_core_size_bytes", "manifest_version", "manifest_file_count"):
            if str(actual_value).strip() != str(expected_value).strip():
                mismatches[key] = {"actual": str(actual_value).strip(), "expected": str(expected_value).strip()}
        else:
            if str(actual_value).strip('"') != str(expected_value).strip('"'):
                mismatches[key] = {"actual": str(actual_value).strip('"'), "expected": str(expected_value).strip('"')}

    if not mismatches:
        return True

    if not write:
        print("release.lua metadata mismatch:")
        for key, values in mismatches.items():
            print(f" - {key}: release={values['actual']} expected={values['expected']}")
        return False

    lines = RELEASE_PATH.read_text(encoding="utf-8").splitlines()
    out = []
    for line in lines:
        replaced = False
        for key, value in expected.items():
            if re.match(rf"\s*{re.escape(key)}\s*=", line):
                out.append(f"  {key} = {value},")
                replaced = True
                break
        if not replaced:
            out.append(line)
    RELEASE_PATH.write_text("\n".join(out) + "\n", encoding="utf-8")
    return True


def run_manifest_sync(write: bool):
    cmd = [sys.executable, str(REPO_ROOT / "scripts" / "manifest_sync.py")]
    if write:
        cmd.append("--write")
    subprocess.run(cmd, cwd=REPO_ROOT, check=True)


def run_cc_parse_guard():
    cmd = [
        sys.executable,
        str(REPO_ROOT / "scripts" / "cc_parse_guard.py"),
        "--file",
        "xreactor/nodes/rt/main.lua",
    ]
    subprocess.run(cmd, cwd=REPO_ROOT, check=True)


def verify_remote_consistency(base_url: str):
    cmd = [
        sys.executable,
        str(REPO_ROOT / "scripts" / "verify_remote_manifest.py"),
        "--base-url",
        base_url,
    ]
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
    parser.add_argument("--verify-url", help="verify published files against published manifest URL after packaging")
    args = parser.parse_args()

    run_cc_parse_guard()
    if args.sync:
        run_manifest_sync(write=True)
        if not sync_release_metadata(write=True):
            print("release.lua metadata mismatch (use --sync)")
            return 1
        # release.lua is part of the manifest; re-sync after metadata updates.
        run_manifest_sync(write=True)
    else:
        run_manifest_sync(write=False)
        if not sync_release_metadata(write=False):
            print("release.lua metadata mismatch (use --sync)")
            return 1

    # Final strict validation pass (must succeed before packaging).
    run_manifest_sync(write=False)

    output_zip = REPO_ROOT / args.output
    build_zip(output_zip)

    if args.verify_url:
        verify_remote_consistency(args.verify_url)

    print(f"Package: {output_zip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
