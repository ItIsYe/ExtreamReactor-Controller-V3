#!/usr/bin/env python3
import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "xreactor/manifest.lua"
CC_PARSE_GUARD = REPO_ROOT / "scripts/cc_parse_guard.py"

PATH_RE = re.compile(r'path\s*=\s*"([^"]+)"')
BASE_FILES_BLOCK_RE = re.compile(r'base_files\s*=\s*\{(.*?)\n\s*\},', re.S)
RT_ROLE_BLOCK_RE = re.compile(r'roles\s*=\s*\{.*?\brt\s*=\s*\{(.*?)\n\s*\},', re.S)
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')


def fail(msg: str) -> None:
    raise SystemExit(msg)


def parse_rt_manifest_paths(manifest_text: str) -> set[str]:
    role_block = RT_ROLE_BLOCK_RE.search(manifest_text)
    if not role_block:
        fail("failed to parse roles.rt block from manifest.lua")
    role_paths = set(PATH_RE.findall(role_block.group(1)))
    if not role_paths:
        fail("roles.rt contains no paths")
    return role_paths


def parse_base_manifest_paths(manifest_text: str) -> set[str]:
    base_block = BASE_FILES_BLOCK_RE.search(manifest_text)
    if not base_block:
        fail("failed to parse base_files block from manifest.lua")
    base_paths = set(PATH_RE.findall(base_block.group(1)))
    if not base_paths:
        fail("base_files contains no paths")
    return base_paths


def module_to_manifest_path(module_name: str) -> str:
    return module_name.replace('.', '/') + '.lua'


def collect_rt_scope(manifest_text: str) -> list[str]:
    rt_paths = parse_rt_manifest_paths(manifest_text)
    base_paths = parse_base_manifest_paths(manifest_text)
    all_manifest_paths = set(PATH_RE.findall(manifest_text))

    queue = list(rt_paths)
    seen = set(rt_paths) | set(base_paths)
    while queue:
        rel = queue.pop(0)
        local_file = REPO_ROOT / "xreactor" / rel
        content = local_file.read_text(encoding="utf-8")
        for mod in REQUIRE_RE.findall(content):
            candidate = module_to_manifest_path(mod)
            if candidate.startswith("xreactor/"):
                candidate = candidate[len("xreactor/"):]
            if candidate not in all_manifest_paths or candidate in seen:
                continue
            seen.add(candidate)
            queue.append(candidate)

    return sorted(seen)


manifest_text = MANIFEST.read_text(encoding="utf-8")
rt_scope = collect_rt_scope(manifest_text)

proc = subprocess.run(
    [
        "python3",
        str(CC_PARSE_GUARD),
        "--chunk-limit",
        "140",
        "--function-limit",
        "170",
        "--max-bytes",
        "120000",
        "--parser-mode",
        "any",
        "--require-real-parse",
        *sum((["--file", str(REPO_ROOT / "xreactor" / rel)] for rel in rt_scope), []),
    ],
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    output = (proc.stdout + "\n" + proc.stderr).strip()
    fail(f"rt_locals_budget_guard_test.py failed:\n{output}")

print("rt_locals_budget_guard_test.py: ok")
