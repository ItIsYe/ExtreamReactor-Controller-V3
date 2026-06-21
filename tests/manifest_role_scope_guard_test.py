#!/usr/bin/env python3
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"
ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*)\}\s*,?\s*$')
REQUIRE_RE = re.compile(r"require\s*\(\s*[\"']([\w\._]+)[\"']\s*\)")

ROLE_CANDIDATES = {
    "services/matrix_sampling_service.lua",
    "nodes/support/discovery.lua",
    "nodes/support/runtime.lua",
    "nodes/support/ui_pages.lua",
    "nodes/support/command_handler.lua",
    "nodes/support/role_logic.lua",
}
ROLE_ENTRYPOINTS = {
    "MASTER": XREACTOR_ROOT / "master" / "main.lua",
    "RT": XREACTOR_ROOT / "nodes" / "rt" / "main.lua",
    "ENERGY": XREACTOR_ROOT / "nodes" / "energy" / "main.lua",
    "WATER": XREACTOR_ROOT / "nodes" / "water" / "main.lua",
    "FUEL": XREACTOR_ROOT / "nodes" / "fuel" / "main.lua",
    "REPROCESSING": XREACTOR_ROOT / "nodes" / "reprocessor" / "main.lua",
    "LOG": XREACTOR_ROOT / "nodes" / "log_collector" / "main.lua",
}

def parse_required_for(tail: str):
    match = re.search(r'required_for\s*=\s*\{([^}]*)\}', tail)
    if not match:
        return None
    return {value.strip().strip('"') for value in match.group(1).split(',') if value.strip()}

def parse_manifest(path: pathlib.Path):
    base_files = set()
    roles_entries = {}
    section = None
    current_role = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if s.startswith("base_files"):
            section = "base"
            current_role = None
            continue
        if s.startswith("roles"):
            section = "roles"
            current_role = None
            continue
        m = re.match(r'([a-z_]+)\s*=\s*\{$', s)
        if section == "roles" and m:
            current_role = m.group(1)
            roles_entries.setdefault(current_role, [])
            continue
        e = ENTRY_RE.match(s)
        if not e:
            continue
        rel = e.group("path")
        rf = parse_required_for(e.group("tail") or "")
        if section == "base":
            base_files.add(rel)
        elif section == "roles" and current_role:
            if not rf:
                rf = {current_role.upper()}
            roles_entries[current_role].append((rel, rf))
    return base_files, roles_entries

def roles_for_path(roles_entries, rel_path):
    out = set()
    for entries in roles_entries.values():
        for path, required_for in entries:
            if path == rel_path:
                out |= set(required_for)
    return out

def module_to_path(module_name: str):
    return module_name.replace('.', '/') + '.lua'

def collect_requires(lua_file: pathlib.Path):
    content = lua_file.read_text(encoding='utf-8')
    return {module_to_path(m.group(1)) for m in REQUIRE_RE.finditer(content)}

def collect_requires_transitive(entry: pathlib.Path):
    """BFS over all reachable require() calls from an entry point."""
    visited, queue = set(), [entry]
    all_requires = set()
    while queue:
        current = queue.pop(0)
        if current in visited or not current.exists():
            continue
        visited.add(current)
        for mod_path in collect_requires(current):
            all_requires.add(mod_path)
            candidate = XREACTOR_ROOT / mod_path
            if candidate.exists() and candidate not in visited:
                queue.append(candidate)
    return all_requires

def expected_roles_from_entrypoints():
    mapping = {path: set() for path in ROLE_CANDIDATES}
    for role, entrypoint in ROLE_ENTRYPOINTS.items():
        requires = collect_requires_transitive(entrypoint)
        for candidate in ROLE_CANDIDATES:
            if candidate in requires:
                mapping[candidate].add(role)
    return mapping

def main():
    base_files, roles_entries = parse_manifest(MANIFEST_PATH)
    expected_by_entry = expected_roles_from_entrypoints()
    errors = []
    for rel_path in sorted(ROLE_CANDIDATES):
        if rel_path in base_files:
            errors.append(f"{rel_path} must not be in base_files")
        actual_roles = roles_for_path(roles_entries, rel_path)
        expected_roles = expected_by_entry[rel_path]
        if actual_roles != expected_roles:
            errors.append(
                f"{rel_path} required_for mismatch expected_from_entrypoints={sorted(expected_roles)} actual={sorted(actual_roles)}"
            )
    if errors:
        print("manifest_role_scope_guard_test.py: FAIL")
        for err in errors:
            print(f" - {err}")
        return 1
    print("manifest_role_scope_guard_test.py: ok")
    return 0

if __name__ == "__main__":
    sys.exit(main())
