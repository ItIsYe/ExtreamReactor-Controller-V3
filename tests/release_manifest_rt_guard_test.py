#!/usr/bin/env python3
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE_PATH = REPO_ROOT / "xreactor" / "release.lua"
MANIFEST_PATH = REPO_ROOT / "xreactor" / "manifest.lua"
INSTALLER_BOOTSTRAP = REPO_ROOT / "installer"
INSTALLER_MAIN = REPO_ROOT / "xreactor" / "installer_main.lua"
RT_MAIN = REPO_ROOT / "xreactor" / "nodes" / "rt" / "main.lua"

SOURCE_REF_RE = re.compile(r'source_ref\s*=\s*"([^"]+)"')
COMMIT_RE = re.compile(r'commit_sha\s*=\s*"([0-9a-f]+)"')
MANIFEST_PATH_RE = re.compile(r'path\s*=\s*"([^"]+)"')
REQUIRE_RE = re.compile(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)')



def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")



def module_to_path(module_name: str) -> str:
    return module_name.replace('.', '/') + '.lua'



def parse_release_commit(text: str) -> str:
    m = COMMIT_RE.search(text)
    if not m:
        raise AssertionError("release.lua commit_sha missing")
    return m.group(1)



def parse_source_ref(text: str) -> str:
    m = SOURCE_REF_RE.search(text)
    if not m:
        raise AssertionError("manifest.lua source_ref missing")
    return m.group(1)



def main() -> int:
    release_text = read(RELEASE_PATH)
    manifest_text = read(MANIFEST_PATH)
    installer_bootstrap_text = read(INSTALLER_BOOTSTRAP)
    installer_main_text = read(INSTALLER_MAIN)
    rt_main_text = read(RT_MAIN)

    release_commit = parse_release_commit(release_text)
    source_ref = parse_source_ref(manifest_text)
    manifest_paths = set(MANIFEST_PATH_RE.findall(manifest_text))

    errors: list[str] = []

    if source_ref != release_commit:
        errors.append(
            f"release/manifest mismatch: release.commit_sha={release_commit} manifest.source_ref={source_ref}"
        )

    mandatory_rt_paths = {
        "nodes/rt/discovery_runtime.lua",
        "nodes/rt/health_payload.lua",
        "nodes/rt/main.lua",
    }
    for path in sorted(mandatory_rt_paths):
        if path not in manifest_paths:
            errors.append(f"manifest missing mandatory RT path: {path}")

    for required_mod in sorted(set(REQUIRE_RE.findall(rt_main_text))):
        required_path = module_to_path(required_mod)
        if required_path.startswith("xreactor/"):
            required_path = required_path[len("xreactor/"):]
        if required_path in manifest_paths:
            continue
        candidate_file = REPO_ROOT / "xreactor" / required_path
        if candidate_file.exists():
            errors.append(
                f"RT require is present on disk but missing in manifest: module={required_mod} path={required_path}"
            )

    if "installer_%s.log" not in installer_main_text:
        errors.append("installer_main.lua no role log naming template installer_%s.log")

    if errors:
        print("release_manifest_rt_guard_test.py: FAIL")
        for err in errors:
            print(" -", err)
        return 1

    print("release_manifest_rt_guard_test.py: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
