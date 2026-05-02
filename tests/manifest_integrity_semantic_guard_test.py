import pathlib
import re
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"

ENTRY_RE = re.compile(
    r'\{\s*path\s*=\s*"([^"]+)"\s*,\s*size_bytes\s*=\s*(\d+)\s*,\s*hash\s*=\s*"([0-9a-fA-F]+)"'
)


def parse_manifest_entries(text: str):
    entries = []
    for path, size, hash_hex in ENTRY_RE.findall(text):
        entries.append({"path": path, "size_bytes": int(size), "hash": hash_hex.lower()})
    if not entries:
        raise AssertionError("manifest contains no file entries")
    return entries


text = MANIFEST_PATH.read_text(encoding="utf-8")
entries = parse_manifest_entries(text)
index = {entry["path"]: entry for entry in entries}

if "master/main.lua" not in index:
    raise AssertionError("manifest must contain master/main.lua entry")

errors = []
for entry in entries:
    local_path = REPO_ROOT / "xreactor" / entry["path"]
    if not local_path.exists():
        errors.append(f"missing file: {entry['path']}")
        continue
    data = local_path.read_bytes()
    size = len(data)
    crc32_hex = f"{zlib.crc32(data) & 0xFFFFFFFF:08x}"
    if size != entry["size_bytes"]:
        errors.append(
            f"size mismatch for {entry['path']}: manifest={entry['size_bytes']} actual={size}"
        )
    if crc32_hex != entry["hash"]:
        errors.append(
            f"hash mismatch for {entry['path']}: manifest={entry['hash']} actual={crc32_hex}"
        )

if errors:
    raise AssertionError("\n".join(errors))

print("manifest_integrity_semantic_guard_test.py: ok")
