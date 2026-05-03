#!/usr/bin/env python3
import re
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "xreactor/manifest.lua"
CC_PARSE_GUARD = REPO_ROOT / "scripts/cc_parse_guard.py"
RELEASE = REPO_ROOT / "xreactor/release.lua"

PATH_RE = re.compile(r'path\s*=\s*"([^"]+)"')
BASE_FILES_BLOCK_RE = re.compile(r'base_files\s*=\s*\{(.*?)\n\s*\},', re.S)
RT_ROLE_BLOCK_RE = re.compile(r'roles\s*=\s*\{.*?\brt\s*=\s*\{(.*?)\n\s*\},', re.S)
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')


def fail(msg: str) -> None:
    raise SystemExit(msg)


def read_release_commit_sha() -> str:
    for line in RELEASE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped.startswith("commit_sha"):
            continue
        parts = stripped.split("=", 1)
        if len(parts) != 2:
            continue
        value = parts[1].strip().rstrip(",").strip().strip('"').strip("'")
        if value:
            return value
    fail(f"commit_sha missing in {RELEASE}")


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
        if not local_file.exists():
            fail(f"manifested RT file missing on disk: {rel}")
        content = local_file.read_text(encoding="utf-8")
        for mod in REQUIRE_RE.findall(content):
            candidate = module_to_manifest_path(mod)
            if candidate.startswith("xreactor/"):
                candidate = candidate[len("xreactor/"):]
            if candidate not in all_manifest_paths:
                continue
            if candidate in seen:
                continue
            seen.add(candidate)
            queue.append(candidate)

    return sorted(seen)


def run_parse_guard(files: list[str], label: str) -> None:
    cmd = [
        "python3",
        str(CC_PARSE_GUARD),
        "--chunk-limit",
        "185",
        "--function-limit",
        "170",
        "--parser-mode",
        "any",
        "--require-real-parse",
    ]
    for rel in files:
        cmd.extend(["--file", str(REPO_ROOT / "xreactor" / rel)])
    guard = subprocess.run(cmd, capture_output=True, text=True)
    if guard.returncode != 0:
        output = (guard.stdout + "\n" + guard.stderr).strip()
        fail(f"cc_parse_guard failed for {label}: {output}")


def main() -> None:
    if not MANIFEST.exists() or not CC_PARSE_GUARD.exists() or not RELEASE.exists():
        fail("required guard inputs are missing")

    manifest_text = MANIFEST.read_text(encoding="utf-8")
    rt_scope = collect_rt_scope(manifest_text)
    run_parse_guard(rt_scope, "working-tree RT delivery scope")

    release_commit = read_release_commit_sha()
    if release_commit != "beta":
        with tempfile.TemporaryDirectory(prefix="rt_release_parse_guard_") as td:
            td_path = Path(td)
            pinned_files = []
            for rel in rt_scope:
                exported = subprocess.run(
                    ["git", "show", f"{release_commit}:xreactor/{rel}"],
                    capture_output=True,
                    text=True,
                )
                if exported.returncode != 0 or not exported.stdout:
                    fail(
                        f"failed to read pinned RT file from commit {release_commit}: {rel}: "
                        f"{(exported.stderr or exported.stdout).strip()}"
                    )
                tmp = td_path / rel
                tmp.parent.mkdir(parents=True, exist_ok=True)
                tmp.write_text(exported.stdout, encoding="utf-8")
                pinned_files.append(str(tmp))

            cmd = [
                "python3",
                str(CC_PARSE_GUARD),
                "--chunk-limit",
                "185",
                "--function-limit",
                "170",
                "--parser-mode",
                "any",
                "--require-real-parse",
            ]
            for path in pinned_files:
                cmd.extend(["--file", path])
            pinned_guard = subprocess.run(cmd, capture_output=True, text=True)
            if pinned_guard.returncode != 0:
                output = (pinned_guard.stdout + "\n" + pinned_guard.stderr).strip()
                fail(
                    "cc_parse_guard failed for release-pinned RT delivery scope "
                    f"(commit {release_commit}): {output}"
                )

    synthetic = Path("/tmp/rt_locals_limit_repro.lua")
    synthetic.write_text("local " + ", ".join(f"v{i}" for i in range(1, 206)) + "\nreturn true\n", encoding="utf-8")
    probe = subprocess.run(
        [
            "python3",
            str(CC_PARSE_GUARD),
            "--file",
            str(synthetic),
            "--chunk-limit",
            "999",
            "--function-limit",
            "999",
            "--parser-mode",
            "any",
            "--require-real-parse",
        ],
        capture_output=True,
        text=True,
    )
    if probe.returncode == 0:
        fail("synthetic >200-locals chunk unexpectedly parsed; real parser guard not effective")
    probe_output = (probe.stdout + "\n" + probe.stderr).lower()
    if "limit is 200" not in probe_output and "more than 200 local variables" not in probe_output and "too many local variables" not in probe_output:
        fail("synthetic >200-locals repro did not report Lua hard-limit error")

    print("rt_main_parse_guard_test.py: ok")


if __name__ == '__main__':
    main()
