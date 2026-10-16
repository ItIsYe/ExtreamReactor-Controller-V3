#!/usr/bin/env python3
# scripts/manifest_sync.py --write only ever updated a changed file's
# size_bytes/hash -- it never touched manifest_version/manifest_id, even
# when a tracked file's actual content changed. installer/auto_update.lua's
# periodic check compares remote_version > local_version: an already-
# deployed node reads that unchanged version and concludes "nothing new",
# so a real content fix pushed to beta without a version bump would never
# reach it. --write must now bump manifest_version (and mirror it into
# manifest_id/release.lua) whenever it actually changed a tracked file --
# and must NOT bump on a no-op re-run.

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(repo_dir, *args):
    return subprocess.run(
        [sys.executable, "scripts/manifest_sync.py", *args],
        cwd=repo_dir,
        capture_output=True,
        text=True,
    )


def read_int(text, key):
    m = re.search(rf'{key}\s*=\s*(\d+)', text)
    if not m:
        raise SystemExit(f"could not find integer field {key!r}")
    return int(m.group(1))


def read_str(text, key):
    m = re.search(rf'{key}\s*=\s*"([^"]*)"', text)
    if not m:
        raise SystemExit(f"could not find string field {key!r}")
    return m.group(1)


with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    shutil.copytree(REPO_ROOT / "xreactor", tmp_path / "xreactor")
    shutil.copytree(REPO_ROOT / "scripts", tmp_path / "scripts")

    manifest_path = tmp_path / "xreactor" / "manifest.lua"
    release_path = tmp_path / "xreactor" / "release.lua"

    old_manifest_text = manifest_path.read_text(encoding="utf-8")
    old_version = read_int(old_manifest_text, "manifest_version")
    old_manifest_id = read_str(old_manifest_text, "manifest_id")

    # Tamper an existing tracked file so --write must actually change its
    # size/hash (same technique as manifest_sync_write_preserves_flags_and_
    # comments_test.py).
    target_rel = "optional/pocket_client.lua"
    target_file = tmp_path / "xreactor" / target_rel
    with target_file.open("a", encoding="utf-8") as f:
        f.write("\n-- tamper for manifest_sync_write_bumps_version_test.py\n")

    proc = run(tmp_path, "--write")
    if proc.returncode != 0:
        raise SystemExit("manifest_sync.py --write failed:\n" + proc.stdout + "\n" + proc.stderr)
    if "Version bump:" not in proc.stdout:
        raise SystemExit("BUG: --write changed a tracked file's content but did not report a version bump.\n"
                          "stdout: " + proc.stdout)

    new_manifest_text = manifest_path.read_text(encoding="utf-8")
    new_version = read_int(new_manifest_text, "manifest_version")
    new_manifest_id = read_str(new_manifest_text, "manifest_id")

    if new_version != old_version + 1:
        raise SystemExit(f"BUG: expected manifest_version {old_version} -> {old_version + 1}, got {new_version}")
    if new_manifest_id != f"manifest-v{new_version}":
        raise SystemExit(f"BUG: expected manifest_id 'manifest-v{new_version}', got {new_manifest_id!r}")

    release_text = release_path.read_text(encoding="utf-8")
    release_version = read_int(release_text, "manifest_version")
    release_manifest_id = read_str(release_text, "manifest_id")
    release_id = read_str(release_text, "release_id")
    if release_version != new_version:
        raise SystemExit(f"BUG: release.lua manifest_version ({release_version}) must match manifest.lua ({new_version})")
    if release_manifest_id != new_manifest_id:
        raise SystemExit(f"BUG: release.lua manifest_id ({release_manifest_id!r}) must match manifest.lua ({new_manifest_id!r})")
    if release_id != f"beta-v{new_version}":
        raise SystemExit(f"BUG: expected release_id 'beta-v{new_version}', got {release_id!r}")

    # A no-op re-run (file already matches the manifest) must NOT bump again.
    proc2 = run(tmp_path, "--write")
    if proc2.returncode != 0:
        raise SystemExit("manifest_sync.py --write (2nd run) failed:\n" + proc2.stdout + "\n" + proc2.stderr)
    if "Version bump:" in proc2.stdout:
        raise SystemExit("BUG: a no-op --write re-run must not bump manifest_version again.\n"
                          "stdout: " + proc2.stdout)
    unchanged_version = read_int(manifest_path.read_text(encoding="utf-8"), "manifest_version")
    if unchanged_version != new_version:
        raise SystemExit(f"BUG: version changed on a no-op re-run: {new_version} -> {unchanged_version}")

print("manifest_sync_write_bumps_version_test.py: ok")
