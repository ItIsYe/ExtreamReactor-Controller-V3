#!/usr/bin/env python3
import pathlib
import re
import sys
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"

ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*)\}\s*,?\s*$')
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')
MANDATORY_ROLE_REQUIRES = {
    "MASTER": {"master.rt_sync_coalescer"},
}
ROLE_SCOPED_CANDIDATES = {
    "services/matrix_sampling_service.lua": {"ENERGY"},
    "nodes/support/discovery.lua": {"WATER", "FUEL", "REPROCESSING"},
    "nodes/support/runtime.lua": {"WATER", "FUEL", "REPROCESSING"},
    "nodes/support/ui_pages.lua": {"WATER", "FUEL", "REPROCESSING"},
    "nodes/support/command_handler.lua": {"WATER", "FUEL", "REPROCESSING"},
    "nodes/support/role_logic.lua": {"ENERGY", "WATER", "FUEL", "REPROCESSING"},
}
CRITICAL_SHIPMENT_PATHS = {
    "master/runtime_loop.lua",
    "master/ui_controller.lua",
    "master/ui/multiview.lua",
    "master/ui/overview.lua",
    "master/ui/rt_dashboard.lua",
    "master/ui/energy.lua",
    "master/message_handlers.lua",
    "master/init_runtime.lua",
    "core/monitor_manager.lua",
}
# Temporary, explicit exceptions for the active MASTER UI rollout.
# The installer accepts omitted size/hash metadata and still downloads + Lua-parses
# these files. Remove entries after regenerating manifest metadata.
MANIFEST_METADATA_OPTIONAL_PATHS = {
    "core/monitor_manager.lua",
    "master/init_runtime.lua",
    "master/ui/multiview.lua",
    "master/ui/rt_dashboard.lua",
}
MASTER_RUNTIME_FINGERPRINT_MARKERS = (
    "Master runtime fingerprint:",
    "snapshot_ui_shape=local",
    "touch_dispatch_diag=enabled",
)

def parse_required_for(tail: str):
    match = re.search(r'required_for\s*=\s*\{([^}]*)\}', tail)
    if not match:
        return None
    return {value.strip().strip('"') for value in match.group(1).split(',') if value.strip()}

def parse_manifest(path: pathlib.Path):
    base_files = []
    metadata = {}
    manifest_entries = set()
    roles = {}
    section = None
    current_role = None

    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if stripped.startswith("base_files"):
            section = "base"
            current_role = None
            continue
        if stripped.startswith("roles"):
            section = "roles"
            current_role = None
            continue

        role_match = re.match(r'([a-z_]+)\s*=\s*\{$', stripped)
        if section == "roles" and role_match:
            current_role = role_match.group(1)
            roles.setdefault(current_role, [])
            continue

        entry_match = ENTRY_RE.match(stripped)
        if not entry_match:
            continue

        rel_path = entry_match.group("path")
        tail = entry_match.group("tail") or ""
        required_for = parse_required_for(entry_match.group("tail") or "")
        manifest_entries.add(rel_path)
        size_match = re.search(r"size_bytes\s*=\s*(\d+)", tail)
        hash_match = re.search(r'hash\s*=\s*"([0-9a-fA-F]+)"', tail)
        if size_match and hash_match:
            metadata[rel_path] = {
                "size_bytes": int(size_match.group(1)),
                "hash": hash_match.group(1).lower(),
            }

        if section == "base":
            base_files.append(rel_path)
        elif section == "roles" and current_role:
            if not required_for:
                required_for = {current_role.upper()}
            roles[current_role].append((rel_path, required_for))

    return base_files, roles, metadata, manifest_entries

def expected_files_for_role(base_files, roles, role_label: str):
    expected = set(base_files)
    for _, entries in roles.items():
        for path, required_for in entries:
            if role_label in required_for:
                expected.add(path)
    return expected

def collect_requires(lua_file: pathlib.Path):
    return {match.group(1) for match in REQUIRE_RE.finditer(lua_file.read_text(encoding="utf-8"))}

def module_to_path(module_name: str):
    return module_name.replace('.', '/') + ".lua"


def collect_role_usage_from_entrypoints(role_specs):
    usage = {path: set() for path in ROLE_SCOPED_CANDIDATES}
    for role_label, entrypoint in role_specs:
        for module_name in collect_requires(entrypoint):
            module_path = module_to_path(module_name)
            if module_path in usage:
                usage[module_path].add(role_label)
    return usage


def main():
    base_files, roles, metadata, manifest_entries = parse_manifest(MANIFEST_PATH)

    role_specs = [
        ("MASTER", XREACTOR_ROOT / "master" / "main.lua"),
        ("RT", XREACTOR_ROOT / "nodes" / "rt" / "main.lua"),
        ("ENERGY", XREACTOR_ROOT / "nodes" / "energy" / "main.lua"),
        ("WATER", XREACTOR_ROOT / "nodes" / "water" / "main.lua"),
        ("FUEL", XREACTOR_ROOT / "nodes" / "fuel" / "main.lua"),
        ("REPROCESSING", XREACTOR_ROOT / "nodes" / "reprocessor" / "main.lua"),
    ]

    errors = []
    warnings = []
    for role_label, entrypoint in role_specs:
        expected = expected_files_for_role(base_files, roles, role_label)
        entrypoint_requires = collect_requires(entrypoint)
        for module_name in sorted(entrypoint_requires):
            module_path = module_to_path(module_name)
            module_abs = XREACTOR_ROOT / module_path
            if not module_abs.exists():
                errors.append(f"role={role_label} entrypoint={entrypoint.relative_to(REPO_ROOT)} requires missing repo module={module_name} path={module_path}")
            if module_path not in expected:
                errors.append(f"role={role_label} entrypoint={entrypoint.relative_to(REPO_ROOT)} missing module={module_name} path={module_path}")
        for mandatory_module in sorted(MANDATORY_ROLE_REQUIRES.get(role_label, set())):
            mandatory_path = module_to_path(mandatory_module)
            if mandatory_module in entrypoint_requires and mandatory_path not in expected:
                errors.append(f"role={role_label} entrypoint={entrypoint.relative_to(REPO_ROOT)} mandatory missing module={mandatory_module} path={mandatory_path}")

    observed_usage = collect_role_usage_from_entrypoints(role_specs)
    for path, configured_roles in sorted(ROLE_SCOPED_CANDIDATES.items()):
        if path in base_files:
            errors.append(f"minimality violation: role-scoped candidate is still global base_files path={path} configured_roles={sorted(configured_roles)}")
        expected_roles = observed_usage.get(path, set())
        if configured_roles != expected_roles:
            errors.append(
                f"role-scope drift: candidate={path} expected_from_entrypoints={sorted(expected_roles)} configured={sorted(configured_roles)}"
            )

    for rel_path in sorted(CRITICAL_SHIPMENT_PATHS):
        entry_meta = metadata.get(rel_path)
        file_path = XREACTOR_ROOT / rel_path
        if rel_path not in manifest_entries:
            errors.append(f"manifest entry missing for critical shipment path={rel_path}")
            continue
        if not file_path.exists():
            errors.append(f"critical shipment path missing in repo path={rel_path}")
            continue
        if not entry_meta:
            if rel_path in MANIFEST_METADATA_OPTIONAL_PATHS:
                warnings.append(f"manifest metadata intentionally omitted during UI rollout path={rel_path}")
                continue
            errors.append(f"manifest metadata missing for critical shipment path={rel_path}")
            continue
        file_bytes = file_path.read_bytes()
        actual_size = len(file_bytes)
        actual_hash = f"{zlib.crc32(file_bytes) & 0xFFFFFFFF:08x}"
        if entry_meta["size_bytes"] != actual_size:
            errors.append(
                f"manifest stale size for critical path={rel_path} expected={actual_size} configured={entry_meta['size_bytes']}"
            )
        if entry_meta["hash"] != actual_hash:
            errors.append(
                f"manifest stale hash for critical path={rel_path} expected={actual_hash} configured={entry_meta['hash']}"
            )

    runtime_loop = (XREACTOR_ROOT / "master" / "runtime_loop.lua").read_text(encoding="utf-8")
    for marker in MASTER_RUNTIME_FINGERPRINT_MARKERS:
        if marker not in runtime_loop:
            errors.append(f"master runtime fingerprint marker missing in runtime_loop.lua marker={marker}")
    if "local function snapshot_ui_shape(" not in runtime_loop:
        errors.append("master runtime snapshot guard missing: local function snapshot_ui_shape(...) not found")

    rt_root = XREACTOR_ROOT / "nodes" / "rt"
    for lua_file in sorted(rt_root.glob("*.lua")):
        for module_name in sorted(collect_requires(lua_file)):
            module_rel = module_to_path(module_name)
            if not (XREACTOR_ROOT / module_rel).exists():
                errors.append(f"rt-file={lua_file.relative_to(REPO_ROOT)} requires missing module={module_name} path={module_rel}")

    if errors:
        print("manifest_entrypoint_require_coverage_test.py: FAIL")
        for err in errors:
            print(f" - {err}")
        return 1

    for warning in warnings:
        print(f"WARN: {warning}")
    print("manifest_entrypoint_require_coverage_test.py: ok")
    return 0

if __name__ == "__main__":
    sys.exit(main())
