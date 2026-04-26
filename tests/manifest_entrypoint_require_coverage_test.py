#!/usr/bin/env python3
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
XREACTOR_ROOT = REPO_ROOT / "xreactor"
MANIFEST_PATH = XREACTOR_ROOT / "manifest.lua"

ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"(?P<path>[^"]+)"(?P<tail>.*)\}\s*,?\s*$')
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')


def parse_required_for(tail: str):
    match = re.search(r'required_for\s*=\s*\{([^}]*)\}', tail)
    if not match:
        return None
    return {value.strip().strip('"') for value in match.group(1).split(',') if value.strip()}


def parse_manifest(path: pathlib.Path):
    base_files = []
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
        required_for = parse_required_for(entry_match.group("tail") or "")

        if section == "base":
            base_files.append(rel_path)
        elif section == "roles" and current_role:
            if not required_for:
                required_for = {current_role.upper()}
            roles[current_role].append((rel_path, required_for))

    return base_files, roles


def expected_files_for_role(base_files, roles, role_label: str):
    expected = set(base_files)
    for _, entries in roles.items():
        for path, required_for in entries:
            if role_label in required_for:
                expected.add(path)
    return expected


def collect_requires(entrypoint: pathlib.Path):
    required = set()
    content = entrypoint.read_text(encoding="utf-8")
    for match in REQUIRE_RE.finditer(content):
        required.add(match.group(1))
    return required


def module_to_path(module_name: str):
    return module_name.replace('.', '/') + ".lua"


def main():
    base_files, roles = parse_manifest(MANIFEST_PATH)

    role_specs = [
        ("MASTER", XREACTOR_ROOT / "master" / "main.lua"),
        ("ENERGY", XREACTOR_ROOT / "nodes" / "energy" / "main.lua"),
        ("WATER", XREACTOR_ROOT / "nodes" / "water" / "main.lua"),
        ("FUEL", XREACTOR_ROOT / "nodes" / "fuel" / "main.lua"),
        ("REPROCESSING", XREACTOR_ROOT / "nodes" / "reprocessor" / "main.lua"),
    ]

    errors = []
    for role_label, entrypoint in role_specs:
        expected = expected_files_for_role(base_files, roles, role_label)
        for module_name in sorted(collect_requires(entrypoint)):
            rel_path = module_to_path(module_name)
            if rel_path not in expected:
                errors.append(
                    f"role={role_label} entrypoint={entrypoint.relative_to(REPO_ROOT)} missing module={module_name} path={rel_path}"
                )

    if errors:
        print("manifest_entrypoint_require_coverage_test.py: FAIL")
        for err in errors:
            print(f" - {err}")
        return 1

    print("manifest_entrypoint_require_coverage_test.py: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
