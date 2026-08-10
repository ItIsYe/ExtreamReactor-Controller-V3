#!/usr/bin/env python3
"""Manifest-Integritaetspruefung.

Prueft:
  - Alle Dateipfade vorhanden
  - CRC32-Hashes korrekt
  - Groessen korrekt
  - Keine Duplikate
  - manifest_version == release.lua manifest_version

Flags:
  --strict   Exit 1 bei jedem Fehler (fuer Deployment-Gate)
"""
import sys, os, re, zlib, argparse

def crc32_hex(path):
    with open(path, "rb") as f:
        return f"{zlib.crc32(f.read()) & 0xFFFFFFFF:08x}"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    errors = []

    manifest_path = "xreactor/manifest.lua"
    if not os.path.exists(manifest_path):
        print(f"ERROR: {manifest_path} not found", file=sys.stderr)
        sys.exit(1)

    with open(manifest_path, encoding="utf-8") as f:
        manifest_src = f.read()

    # Eintraege: path, size_bytes (optional), hash (optional)
    entry_re = re.compile(
        r'\{\s*path\s*=\s*"([^"]+)"'
        r'(?:[^}]*?size_bytes\s*=\s*(\d+))?'
        r'(?:[^}]*?hash\s*=\s*"([0-9a-fA-F]+)")?',
        re.DOTALL)

    manifest_ver = re.search(r'manifest_version\s*=\s*(\d+)', manifest_src)
    seen = set()
    count = 0

    for m in entry_re.finditer(manifest_src):
        path, size_str, hash_str = m.group(1), m.group(2), m.group(3)
        full = os.path.join("xreactor", path)
        count += 1

        if path in seen:
            errors.append(f"DUPLICATE: {path}")
        seen.add(path)

        if not os.path.exists(full):
            errors.append(f"MISSING: {full}")
            continue

        if not hash_str:
            errors.append(f"HASH_MISSING: {path}")
        else:
            actual = crc32_hex(full)
            if actual != hash_str:
                errors.append(f"HASH_MISMATCH: {path}  expected={hash_str}  actual={actual}")

        if not size_str:
            errors.append(f"SIZE_MISSING: {path}")
        else:
            actual_sz = os.path.getsize(full)
            if actual_sz != int(size_str):
                errors.append(f"SIZE_MISMATCH: {path}  expected={size_str}  actual={actual_sz}")

    # Jede produktive Lua-Datei unter xreactor muss manifestiert sein. Das
    # Manifest selbst ist die einzige Ausnahme, da es sich nicht selbst stabil
    # hashen kann.
    source_files = set()
    for root, _dirs, files in os.walk("xreactor"):
        for filename in files:
            if not filename.endswith(".lua"):
                continue
            rel = os.path.relpath(os.path.join(root, filename), "xreactor").replace(os.sep, "/")
            if rel != "manifest.lua":
                source_files.add(rel)
    for path in sorted(source_files - seen):
        errors.append(f"UNLISTED_SOURCE: {path}")
    for path in sorted(seen - source_files):
        errors.append(f"NON_SOURCE_ENTRY: {path}")

    # release.lua Versionskonsistenz
    release_path = "xreactor/release.lua"
    if os.path.exists(release_path):
        with open(release_path, encoding="utf-8") as f:
            rel_src = f.read()
        rel_ver = re.search(r'manifest_version\s*=\s*(\d+)', rel_src)
        rel_count = re.search(r'manifest_file_count\s*=\s*(\d+)', rel_src)
        if manifest_ver and rel_ver and manifest_ver.group(1) != rel_ver.group(1):
            errors.append(
                f"VERSION_MISMATCH: manifest={manifest_ver.group(1)}"
                f" release={rel_ver.group(1)}")
        if not rel_count:
            errors.append("RELEASE_COUNT_MISSING: manifest_file_count")
        elif int(rel_count.group(1)) != count:
            errors.append(
                f"RELEASE_COUNT_MISMATCH: release={rel_count.group(1)} manifest={count}")

    if errors:
        print(f"ERRORS ({len(errors)}):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {count} entries validated")

if __name__ == "__main__":
    main()
