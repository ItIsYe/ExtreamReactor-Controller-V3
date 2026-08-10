#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"

ENTRY_RE = re.compile(r'^\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*)\}\s*,?\s*$')
SIZE_RE = re.compile(r'\bsize_bytes\s*=\s*(\d+)')
HASH_RE = re.compile(r'\bhash\s*=\s*"([0-9a-fA-F]+)"')
KV_RE = re.compile(r'^\s*(manifest_version|manifest_id|source_ref|hash_algo)\s*=\s*(.+?),\s*$')


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_flags(tail: str):
    flags = {}
    if re.search(r'\balways\s*=\s*true\b', tail):
        flags["always"] = True
    if re.search(r'\boptional\s*=\s*true\b', tail):
        flags["optional"] = True
    feature_match = re.search(r'\bfeature\s*=\s*"([^"]+)"', tail)
    if feature_match:
        flags["feature"] = feature_match.group(1)
    req_match = re.search(r'required_for\s*=\s*\{([^}]*)\}', tail)
    if req_match:
        values = [v.strip().strip('"') for v in req_match.group(1).split(',') if v.strip()]
        flags["required_for"] = values
    return flags


def parse_manifest(path: pathlib.Path):
    text = path.read_text(encoding="utf-8")
    top = {}
    base_files, dev_files = [], []
    roles = {}
    section = None
    current_role = None

    for raw in text.splitlines():
        kv = KV_RE.match(raw)
        if kv:
            top[kv.group(1)] = kv.group(2)

        line = raw.strip()
        if line.startswith("base_files"):
            section = "base"
            current_role = None
            continue
        if line.startswith("dev_files"):
            section = "dev"
            current_role = None
            continue
        if line.startswith("roles"):
            section = "roles"
            current_role = None
            continue
        role_match = re.match(r'([a-z_]+)\s*=\s*\{$', line)
        if section == "roles" and role_match:
            current_role = role_match.group(1)
            roles.setdefault(current_role, [])
            continue

        entry_match = ENTRY_RE.match(line)
        if not entry_match:
            continue

        tail = entry_match.group("tail") or ""
        size_match = SIZE_RE.search(tail)
        hash_match = HASH_RE.search(tail)
        if not size_match or not hash_match:
            raise RuntimeError(
                f'manifest entry requires size_bytes and hash: {entry_match.group("path")}'
            )

        item = {
            "path": entry_match.group("path"),
            "size_bytes": int(size_match.group(1)),
            "hash": hash_match.group(1).lower(),
            "flags": parse_flags(tail),
        }
        if section == "base":
            base_files.append(item)
        elif section == "dev":
            dev_files.append(item)
        elif section == "roles" and current_role:
            roles[current_role].append(item)

    if not base_files:
        raise RuntimeError("failed to parse manifest entries")
    return top, base_files, dev_files, roles


def update_entry(entry):
    file_path = REPO_ROOT / "xreactor" / entry["path"]
    if not file_path.exists():
        raise FileNotFoundError(f"missing manifest file: {entry['path']}")
    content = file_path.read_bytes()
    entry["size_bytes"] = len(content)
    entry["hash"] = crc32_hex(content)


def validate_entries(entries, errors, seen):
    checked = 0
    for entry in entries:
        rel = entry["path"]
        if rel in seen:
            errors.append(f"duplicate manifest path: {rel}")
            continue
        seen.add(rel)
        file_path = REPO_ROOT / "xreactor" / rel
        if not file_path.exists():
            errors.append(f"missing file: {rel}")
            continue
        content = file_path.read_bytes()
        actual_size = len(content)
        actual_hash = crc32_hex(content)
        if actual_size != entry["size_bytes"]:
            errors.append(f"size mismatch for {rel}: manifest={entry['size_bytes']} actual={actual_size}")
        if actual_hash != entry["hash"]:
            errors.append(f"hash mismatch for {rel}: manifest={entry['hash']} actual={actual_hash}")
        checked += 1
    return checked


def format_entry(entry):
    extras = []
    flags = entry.get("flags", {})
    if flags.get("always"):
        extras.append("always = true")
    if flags.get("optional"):
        extras.append("optional = true")
    feature = flags.get("feature")
    if feature:
        extras.append(f'feature = "{feature}"')
    req = flags.get("required_for")
    if req:
        joined = ", ".join(f'"{value}"' for value in req)
        extras.append(f"required_for = {{ {joined} }}")
    suffix = ""
    if extras:
        suffix = ", " + ", ".join(extras)
    return f'      {{ path = "{entry["path"]}", size_bytes = {entry["size_bytes"]}, hash = "{entry["hash"]}"{suffix} }},'


def write_manifest(top, base_files, dev_files, roles):
    manifest_version = top.get("manifest_version", "6")
    manifest_id = top.get("manifest_id", '"manifest-v6"')
    source_ref = top.get("source_ref", '"beta"')
    hash_algo = top.get("hash_algo", '"crc32"')
    manifest_label = str(manifest_id).strip('"')
    lines = [f"-- xreactor/manifest.lua -- {manifest_label}", "return {"]
    lines.append(f"  manifest_version = {manifest_version},")
    lines.append(f"  manifest_id = {manifest_id},")
    lines.append(f"  source_ref = {source_ref},")
    lines.append(f"  hash_algo = {hash_algo},")
    lines.append("  base_files = {")
    for e in base_files:
        lines.append(format_entry(e))
    lines.append("  },")
    lines.append("  dev_files = {")
    for e in dev_files:
        lines.append(format_entry(e))
    lines.append("  },")
    lines.append("  roles = {")
    for role, entries in roles.items():
        lines.append(f"    {role} = {{")
        for e in entries:
            lines.append(format_entry(e))
        lines.append("    },")
    lines.append("  }")
    lines.append("}")
    MANIFEST_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def all_entries(base_files, dev_files, roles):
    entries = []
    entries.extend(base_files)
    entries.extend(dev_files)
    for role in roles.values():
        entries.extend(role)
    return entries


def main():
    parser = argparse.ArgumentParser(description="Validate/sync xreactor manifest entries")
    parser.add_argument("--write", action="store_true", help="Rewrite manifest with current file size/hash values")
    parser.add_argument("--check", action="store_true", help="Check-only mode (default: check without writing)")
    args = parser.parse_args()

    top, base_files, dev_files, roles = parse_manifest(MANIFEST_PATH)
    entries = all_entries(base_files, dev_files, roles)

    if args.write:
        for entry in entries:
            update_entry(entry)
        write_manifest(top, base_files, dev_files, roles)

    errors = []
    checked = 0
    seen = set()
    checked += validate_entries(base_files, errors, seen)
    checked += validate_entries(dev_files, errors, seen)
    for role_entries in roles.values():
        checked += validate_entries(role_entries, errors, seen)

    manifest_id = str(top.get("manifest_id", '"unknown"')).strip('"')
    if errors:
        print(f"Manifest-ID: {manifest_id}")
        print(f"Checked files: {checked}")
        print("Consistency: FAIL")
        for error in errors:
            print(f" - {error}")
        return 1

    print(f"Manifest-ID: {manifest_id}")
    print(f"Checked files: {checked}")
    print("Consistency: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
