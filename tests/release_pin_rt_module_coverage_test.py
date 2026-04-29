#!/usr/bin/env python3
import pathlib
import re
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE_PATH = REPO_ROOT / "xreactor" / "release.lua"
RT_MAIN_PATH = REPO_ROOT / "xreactor" / "nodes" / "rt" / "main.lua"
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')

ALIASES = {
    "adapters.runtime_ctx.monitor": ["adapters/monitor.lua"],
    "nodes.rt.runtime_ctx.status_snapshot": ["nodes/rt/status_snapshot.lua"],
}


def read_release_sha() -> str:
    text = RELEASE_PATH.read_text(encoding="utf-8")
    match = re.search(r'commit_sha\s*=\s*"([0-9a-f]+)"', text)
    if not match:
        raise RuntimeError("release.lua commit_sha missing")
    return match.group(1)


def git_show(sha: str, rel_path: str) -> str:
    return subprocess.check_output(["git", "show", f"{sha}:{rel_path}"], cwd=REPO_ROOT, text=True)


def parse_manifest_paths(manifest_text: str) -> set[str]:
    return set(re.findall(r'path\s*=\s*"([^"]+)"', manifest_text))


def module_to_paths(module_name: str) -> list[str]:
    return [module_name.replace('.', '/') + '.lua', *ALIASES.get(module_name, [])]


def collect_rt_requires() -> set[str]:
    content = RT_MAIN_PATH.read_text(encoding="utf-8")
    return {m.group(1) for m in REQUIRE_RE.finditer(content)}


def main() -> int:
    release_sha = read_release_sha()
    manifest_text = git_show(release_sha, "xreactor/manifest.lua")
    manifest_paths = parse_manifest_paths(manifest_text)

    missing = []
    for mod in sorted(collect_rt_requires()):
      candidates = module_to_paths(mod)
      if not any(path in manifest_paths for path in candidates):
          missing.append((mod, candidates))

    if missing:
        print("release_pin_rt_module_coverage_test.py: FAIL")
        print(f" - release commit_sha={release_sha}")
        for mod, candidates in missing:
            print(f" - missing module={mod} manifest_paths={candidates}")
        return 1

    print("release_pin_rt_module_coverage_test.py: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
