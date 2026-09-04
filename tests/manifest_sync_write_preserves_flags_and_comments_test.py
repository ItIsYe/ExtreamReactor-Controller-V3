#!/usr/bin/env python3
# scripts/manifest_sync.py --write regenerated the ENTIRE manifest.lua from
# parsed fields (write_manifest()/format_entry()). parse_flags() only ever
# recognized "always"/"required_for" -- every "optional=true" and
# "feature=\"...\"" flag on optional-feature entries (e.g.
# optional/pocket_client.lua) was silently dropped on rewrite, and every
# comment in the file (there are many, explaining individual entries) was
# discarded outright since the regeneration only knew about structured
# entries, not free text. --write must instead patch only size_bytes/hash
# in place within each entry's own line, leaving everything else --
# comments, flags, formatting, ordering -- byte-identical to the original.

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


with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    # Nur die fuer manifest_sync.py relevanten Teile kopieren (kompletter
    # Checkout waere unnoetig langsam/gross).
    shutil.copytree(REPO_ROOT / "xreactor", tmp_path / "xreactor")
    shutil.copytree(REPO_ROOT / "scripts", tmp_path / "scripts")

    original_text = (tmp_path / "xreactor" / "manifest.lua").read_text(encoding="utf-8")

    # Eine bestehende optional=true/feature=".."-Datei absichtlich veraendern,
    # damit --write tatsaechlich eine Aenderung an Groesse/Hash vornehmen muss.
    target_rel = "optional/pocket_client.lua"
    target_file = tmp_path / "xreactor" / target_rel
    with target_file.open("a", encoding="utf-8") as f:
        f.write("\n-- tamper for manifest_sync_write_preserves_flags_and_comments_test.py\n")

    proc = run(tmp_path, "--write")
    if proc.returncode != 0:
        raise SystemExit(
            "manifest_sync.py --write failed:\n" + proc.stdout + "\n" + proc.stderr
        )

    new_text = (tmp_path / "xreactor" / "manifest.lua").read_text(encoding="utf-8")

    # Die Zeile fuer die veraenderte Datei muss optional=true und
    # feature="pocket_client" weiterhin tragen -- das war der zentrale Bug.
    line_match = re.search(
        r'\{\s*path\s*=\s*"' + re.escape(target_rel) + r'".*\}', new_text
    )
    if not line_match:
        raise SystemExit(f"could not find manifest entry line for {target_rel} after --write")
    entry_line = line_match.group(0)
    if "optional=true" not in entry_line and "optional = true" not in entry_line:
        raise SystemExit(
            "BUG: optional=true flag was dropped by --write, line is now: " + entry_line
        )
    if 'feature="pocket_client"' not in entry_line and 'feature = "pocket_client"' not in entry_line:
        raise SystemExit(
            "BUG: feature=\"pocket_client\" flag was dropped by --write, line is now: " + entry_line
        )

    # Groesse/Hash muessen sich tatsaechlich geaendert haben (sonst wuerde
    # der Test nichts pruefen).
    old_line_match = re.search(
        r'\{\s*path\s*=\s*"' + re.escape(target_rel) + r'".*\}', original_text
    )
    if old_line_match.group(0) == entry_line:
        raise SystemExit("test setup error: entry line did not change after tampering + --write")

    # Kommentare im Manifest (es gibt mehrere erklaerende Bloecke) muessen
    # vollstaendig erhalten bleiben -- vorher wurden sie beim Neuaufbau
    # komplett verworfen.
    original_comment_lines = [
        line for line in original_text.splitlines() if line.strip().startswith("--")
    ]
    new_comment_lines = [
        line for line in new_text.splitlines() if line.strip().startswith("--")
    ]
    if len(original_comment_lines) == 0:
        raise SystemExit("test setup error: manifest.lua has no comment lines to verify against")
    if original_comment_lines != new_comment_lines:
        raise SystemExit(
            "BUG: --write altered/dropped manifest comments.\n"
            f"before: {len(original_comment_lines)} comment lines, after: {len(new_comment_lines)}"
        )

    # Jede andere, nicht veraenderte Eintragszeile muss byteidentisch bleiben.
    # Ein echter Inhaltswechsel loest jetzt (siehe manifest_sync_write_bumps_
    # version_test.py) zusaetzlich einen Versions-Bump aus -- das aendert
    # neben der manipulierten Zeile auch manifest_version/manifest_id UND
    # release.lua's eigenen Manifest-Eintrag (release.lua wird durch den
    # Bump selbst neu geschrieben). Erwartet also genau diese 4 Zeilen,
    # nicht mehr nur die eine manipulierte.
    original_lines = original_text.splitlines()
    new_lines = new_text.splitlines()
    if len(original_lines) != len(new_lines):
        raise SystemExit(
            f"BUG: --write changed the total line count ({len(original_lines)} -> {len(new_lines)}); "
            "expected only the tampered entry's line (plus the version-bump lines) to change"
        )
    changed = [
        (i, a, b)
        for i, (a, b) in enumerate(zip(original_lines, new_lines))
        if a != b
    ]
    changed_prefixes = tuple(a.strip() for _, a, _ in changed)
    expected_prefix_starts = ("manifest_version", "manifest_id", '{ path = "release.lua"')
    unexpected = [
        (i, a, b) for i, a, b in changed
        if target_rel not in a and not a.strip().startswith(expected_prefix_starts)
    ]
    if unexpected:
        raise SystemExit(
            f"BUG: unexpected changed line(s) beyond the tampered entry and version bump: {unexpected}"
        )
    if len(changed) != 4:
        raise SystemExit(
            f"BUG: expected exactly 4 changed lines (tampered entry, manifest_version, "
            f"manifest_id, release.lua's own entry), got {len(changed)}: {changed}"
        )

print("manifest_sync_write_preserves_flags_and_comments_test.py: ok")
