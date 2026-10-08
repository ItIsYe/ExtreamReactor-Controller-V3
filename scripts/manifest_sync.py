#!/usr/bin/env python3
import argparse
import pathlib
import re
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"

ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)",\s*size_bytes\s*=\s*(?P<size>\d+),\s*hash\s*=\s*"(?P<hash>[0-9a-f]+)"(?P<tail>.*)\}\s*,?\s*$')
KV_RE = re.compile(r'^\s*(manifest_version|manifest_id|source_ref|hash_algo)\s*=\s*(.+?),\s*$')


def crc32_hex(content: bytes) -> str:
    return f"{zlib.crc32(content) & 0xFFFFFFFF:08x}"


def parse_flags(tail: str):
    flags = {}
    if "always = true" in tail:
        flags["always"] = True
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

        item = {
            "path": entry_match.group("path"),
            "size_bytes": int(entry_match.group("size")),
            "hash": entry_match.group("hash"),
            "flags": parse_flags(entry_match.group("tail") or ""),
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


SIZE_BYTES_RE = re.compile(r'size_bytes\s*=\s*\d+')
HASH_RE = re.compile(r'hash\s*=\s*"[0-9a-f]+"')


def write_manifest_inplace(path: pathlib.Path, entries):
    # Frueher hat write_manifest() die komplette Datei aus den geparsten
    # Feldern neu zusammengesetzt (siehe format_entry()) -- geparst wurden
    # dabei nur "always" und "required_for" (parse_flags()), sodass jedes
    # "optional=true"/"feature=\"...\""-Flag beim Neuaufbau stillschweigend
    # verloren ging, und JEDER Kommentar in der Datei (Zeilen wie die
    # Erklaerung ueber optional/pocket_client.lua) mit weggeworfen wurde,
    # weil die Regeneration nur strukturierte Eintraege kennt, keinen
    # Freitext. Ersetzt jetzt stattdessen NUR size_bytes/hash direkt in der
    # jeweiligen Original-Zeile (Regex-Substitution), der Rest der Datei --
    # Kommentare, Flags, Formatierung, Reihenfolge -- bleibt byteidentisch
    # zum Original erhalten.
    text = path.read_text(encoding="utf-8")
    by_path = {e["path"]: e for e in entries}
    had_trailing_newline = text.endswith("\n")
    lines = text.splitlines()
    out_lines = []
    for raw in lines:
        entry_match = ENTRY_RE.match(raw.strip())
        entry = entry_match and by_path.get(entry_match.group("path"))
        if entry:
            new_line = SIZE_BYTES_RE.sub(f'size_bytes = {entry["size_bytes"]}', raw, count=1)
            new_line = HASH_RE.sub(f'hash = "{entry["hash"]}"', new_line, count=1)
            out_lines.append(new_line)
        else:
            out_lines.append(raw)
    new_text = "\n".join(out_lines)
    if had_trailing_newline:
        new_text += "\n"
    path.write_text(new_text, encoding="utf-8")


def all_entries(base_files, dev_files, roles):
    entries = []
    entries.extend(base_files)
    entries.extend(dev_files)
    for role in roles.values():
        entries.extend(role)
    return entries


# Pruefsumme ueber den INHALT einer Fassung (Betreiberentscheidung
# 2026-10-08: "fuer Dateien Pruefsumme, um festzustellen, wie alt sie sind
# und ob sie noch genommen werden duerfen"). CRC32 ueber Pfad, Groesse und
# Hash jedes Manifest-Eintrags, sortiert nach Pfad. release.lua bleibt
# draussen: sie TRAEGT die Pruefsumme, ihr eigener Hash haengt also davon ab
# (dieselbe Selbstbezueglichkeit wie beim Versionszaehler unten).
# Steht in manifest.lua UND release.lua; der Installer schreibt sie mit den
# Einzel-Pruefsummen auf jeden Knoten (install_hashes.lua), und
# core/install_integrity.lua prueft die installierten Dateien dagegen.
PAYLOAD_DIGEST_EXCLUDED = {"release.lua"}
PAYLOAD_DIGEST_RE = re.compile(r'(payload_digest\s*=\s*")([0-9a-f]*)(",)')
MANIFEST_ID_LINE_RE = re.compile(r'^(\s*)manifest_id\s*=\s*"[^"]*",[ \t]*$', re.M)


def compute_payload_digest(entries) -> str:
    lines = sorted(
        f'{e["path"]}\t{e["size_bytes"]}\t{e["hash"]}'
        for e in entries
        if e["path"] not in PAYLOAD_DIGEST_EXCLUDED
    )
    return crc32_hex(("\n".join(lines) + "\n").encode("utf-8"))


def read_payload_digest(path: pathlib.Path):
    if not path.exists():
        return None
    match = PAYLOAD_DIGEST_RE.search(path.read_text(encoding="utf-8"))
    return match.group(2) if match else None


def write_payload_digest(path: pathlib.Path, digest: str) -> bool:
    """Setzt payload_digest; fehlt das Feld, kommt es direkt unter manifest_id.
    True, wenn sich die Datei geaendert hat."""
    text = path.read_text(encoding="utf-8")
    if PAYLOAD_DIGEST_RE.search(text):
        new_text = PAYLOAD_DIGEST_RE.sub(rf'\g<1>{digest}\3', text, count=1)
    else:
        match = MANIFEST_ID_LINE_RE.search(text)
        if not match:
            raise RuntimeError(f"no manifest_id line in {path.name} to anchor payload_digest")
        insert = f'\n{match.group(1)}payload_digest = "{digest}",'
        new_text = text[:match.end()] + insert + text[match.end():]
    if new_text == text:
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


MANIFEST_VERSION_RE = re.compile(r'(manifest_version\s*=\s*)(\d+)(,)')
MANIFEST_ID_RE = re.compile(r'(manifest_id\s*=\s*")manifest-v(\d+)(",)')
RELEASE_PATH = REPO_ROOT / "xreactor" / "release.lua"
RELEASE_VERSION_RE = re.compile(r'(manifest_version\s*=\s*)(\d+)(,)')
RELEASE_ID_RE = re.compile(r'(manifest_id\s*=\s*")manifest-v(\d+)(",)')
RELEASE_FILE_COUNT_RE = re.compile(r'(manifest_file_count\s*=\s*)(\d+)(,)')
RELEASE_ID_FIELD_RE = re.compile(r'(release_id\s*=\s*")beta-v(\d+)(",)')


def bump_version(file_count: int) -> int:
    """Bumps manifest_version/manifest_id in manifest.lua and mirrors
    manifest_version/manifest_id/manifest_file_count/release_id into
    release.lua. Returns the new version.

    Without this, a content-only change (same file count, different hash)
    left manifest_version unchanged: installer/auto_update.lua's periodic
    check compares remote_version > local_version, so an already-deployed
    node would see "no update" and never pull a real fix -- exactly what
    happened across several merged beta commits before this was added.
    """
    text = MANIFEST_PATH.read_text(encoding="utf-8")
    version_match = MANIFEST_VERSION_RE.search(text)
    if not version_match:
        raise RuntimeError("could not find manifest_version in manifest.lua")
    old_version = int(version_match.group(2))
    new_version = old_version + 1

    bumped = MANIFEST_VERSION_RE.sub(rf'\g<1>{new_version}\3', text, count=1)
    bumped = MANIFEST_ID_RE.sub(rf'\g<1>manifest-v{new_version}\3', bumped, count=1)
    MANIFEST_PATH.write_text(bumped, encoding="utf-8")

    if RELEASE_PATH.exists():
        release_text = RELEASE_PATH.read_text(encoding="utf-8")
        release_text = RELEASE_VERSION_RE.sub(rf'\g<1>{new_version}\3', release_text, count=1)
        release_text = RELEASE_ID_RE.sub(rf'\g<1>manifest-v{new_version}\3', release_text, count=1)
        release_text = RELEASE_FILE_COUNT_RE.sub(rf'\g<1>{file_count}\3', release_text, count=1)
        release_text = RELEASE_ID_FIELD_RE.sub(rf'\g<1>beta-v{new_version}\3', release_text, count=1)
        RELEASE_PATH.write_text(release_text, encoding="utf-8")

    print(f"Version bump: {old_version} -> {new_version} (manifest.lua + release.lua)")
    return new_version


def main():
    parser = argparse.ArgumentParser(description="Validate/sync xreactor manifest entries")
    parser.add_argument("--write", action="store_true", help="Rewrite manifest with current file size/hash values")
    parser.add_argument("--check", action="store_true", help="Check-only mode (default: check without writing)")
    args = parser.parse_args()

    top, base_files, dev_files, roles = parse_manifest(MANIFEST_PATH)
    entries = all_entries(base_files, dev_files, roles)

    if args.write:
        # release.lua is itself a manifest-tracked entry. It carries the
        # version fields, so bumping the version below inherently changes
        # release.lua's own bytes too -- excluded here so that natural,
        # self-referential drift is never mistaken for a "real" content
        # change and does not cause the bump to (re-)trigger itself.
        changed_paths = []
        for entry in entries:
            old_hash = entry["hash"]
            update_entry(entry)
            if entry["hash"] != old_hash and entry["path"] != "release.lua":
                changed_paths.append(entry["path"])
        write_manifest_inplace(MANIFEST_PATH, entries)

        if changed_paths:
            bump_version(len(entries))

        # Inhalts-Pruefsumme in manifest.lua und release.lua nachziehen. Sie
        # aendert sich nur, wenn sich ein Eintrag (ausser release.lua)
        # aendert -- also genau dann, wenn auch die Fassung gehoben wurde.
        digest = compute_payload_digest(entries)
        write_payload_digest(MANIFEST_PATH, digest)
        if RELEASE_PATH.exists():
            write_payload_digest(RELEASE_PATH, digest)

        release_entry = next((e for e in entries if e["path"] == "release.lua"), None)
        if release_entry:
            update_entry(release_entry)
            write_manifest_inplace(MANIFEST_PATH, [release_entry])

    errors = []
    checked = 0
    seen = set()
    checked += validate_entries(base_files, errors, seen)
    checked += validate_entries(dev_files, errors, seen)
    for role_entries in roles.values():
        checked += validate_entries(role_entries, errors, seen)

    # Die Inhalts-Pruefsumme muss zu den Eintraegen passen -- in manifest.lua
    # und in release.lua (die Knoten lesen sie aus release.lua).
    digest = compute_payload_digest(all_entries(base_files, dev_files, roles))
    for label, path in (("manifest.lua", MANIFEST_PATH), ("release.lua", RELEASE_PATH)):
        stored = read_payload_digest(path)
        if stored is None:
            errors.append(f"payload_digest missing in {label} (expected {digest})")
        elif stored != digest:
            errors.append(f"payload_digest mismatch in {label}: stored={stored} actual={digest}")

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
