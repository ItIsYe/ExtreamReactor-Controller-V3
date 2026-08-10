#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
script = root / "scripts" / "manifest_sync.py"
spec = importlib.util.spec_from_file_location("manifest_sync", script)
manifest_sync = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(manifest_sync)

top, base_files, dev_files, roles = manifest_sync.parse_manifest(root / "xreactor" / "manifest.lua")
entries = manifest_sync.all_entries(base_files, dev_files, roles)
by_path = {entry["path"]: entry for entry in entries}

assert len(entries) == 174, f"expected 174 manifest entries, got {len(entries)}"
for required in ("release.lua", "installer/journal.lua"):
    assert required in by_path, f"parser silently skipped {required}"

optional = by_path["optional/pocket_client.lua"]
assert optional["flags"].get("optional") is True
assert optional["flags"].get("feature") == "pocket_client"

with tempfile.TemporaryDirectory(prefix="xreactor-manifest-roundtrip-") as temp_dir:
    temp_manifest = pathlib.Path(temp_dir) / "manifest.lua"
    original_path = manifest_sync.MANIFEST_PATH
    try:
        manifest_sync.MANIFEST_PATH = temp_manifest
        manifest_sync.write_manifest(top, base_files, dev_files, roles)
        top2, base2, dev2, roles2 = manifest_sync.parse_manifest(temp_manifest)
        rendered = temp_manifest.read_text(encoding="utf-8")
    finally:
        manifest_sync.MANIFEST_PATH = original_path

entries2 = manifest_sync.all_entries(base2, dev2, roles2)
by_path2 = {entry["path"]: entry for entry in entries2}
assert len(entries2) == len(entries)
assert by_path2["optional/pocket_client.lua"]["flags"].get("optional") is True
assert by_path2["optional/pocket_client.lua"]["flags"].get("feature") == "pocket_client"
assert rendered.startswith(
    f"-- xreactor/manifest.lua -- {str(top['manifest_id']).strip(chr(34))}\n"
)

print("manifest_tooling_semantics_test.py: ok")
