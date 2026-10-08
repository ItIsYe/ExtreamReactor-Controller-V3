#!/usr/bin/env python3
# Inhalts-Pruefsumme einer Fassung (payload_digest).
#
# Betreiberentscheidung 2026-10-08: "fuer Dateien Pruefsumme, um
# festzustellen, wie alt sie sind und ob sie noch genommen werden duerfen".
# scripts/manifest_sync.py schreibt eine CRC32 ueber Pfad, Groesse und Hash
# aller Manifest-Eintraege (ausser release.lua, die sie traegt) in
# manifest.lua und release.lua; die Knoten pruefen ihre Dateien dagegen
# (core/install_integrity.lua).
#
#   1. die Pruefsumme im Repo passt zu den Eintraegen -- unabhaengig hier
#      nachgerechnet, nicht mit der Funktion des Skripts
#   2. aendert sich eine Datei, aendert --write die Pruefsumme mit
#   3. --check erkennt eine veraltete Pruefsumme

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY_RE = re.compile(r'\{\s*path\s*=\s*"([^"]+)",\s*size_bytes\s*=\s*(\d+),\s*hash\s*=\s*"([0-9a-f]+)"')
DIGEST_RE = re.compile(r'payload_digest\s*=\s*"([0-9a-f]+)"')


def expected_digest(manifest_text):
    lines = sorted(
        f"{path}\t{size}\t{digest}"
        for path, size, digest in ENTRY_RE.findall(manifest_text)
        if path != "release.lua"
    )
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    return f"{zlib.crc32(payload) & 0xFFFFFFFF:08x}"


def stored(path):
    m = DIGEST_RE.search(path.read_text(encoding="utf-8"))
    if not m:
        raise SystemExit(f"BUG: payload_digest fehlt in {path.name}")
    return m.group(1)


def run(repo_dir, *args):
    return subprocess.run([sys.executable, "scripts/manifest_sync.py", *args],
                          cwd=repo_dir, capture_output=True, text=True)


# 1. Im Repo
manifest = REPO_ROOT / "xreactor" / "manifest.lua"
release = REPO_ROOT / "xreactor" / "release.lua"
want = expected_digest(manifest.read_text(encoding="utf-8"))
if stored(manifest) != want:
    raise SystemExit(f"BUG: manifest.lua payload_digest={stored(manifest)}, erwartet {want}")
if stored(release) != want:
    raise SystemExit(f"BUG: release.lua payload_digest={stored(release)}, erwartet {want}")

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = pathlib.Path(tmp)
    shutil.copytree(REPO_ROOT / "xreactor", tmp_path / "xreactor")
    shutil.copytree(REPO_ROOT / "scripts", tmp_path / "scripts")
    t_manifest = tmp_path / "xreactor" / "manifest.lua"
    t_release = tmp_path / "xreactor" / "release.lua"

    # 2. Eine Datei aendert sich
    before = stored(t_manifest)
    target = tmp_path / "xreactor" / "optional" / "pocket_client.lua"
    target.write_text(target.read_text(encoding="utf-8") + "\n-- geaendert\n", encoding="utf-8")
    result = run(tmp_path, "--write")
    if result.returncode != 0:
        raise SystemExit(f"BUG: --write schlug fehl:\n{result.stdout}\n{result.stderr}")
    after = stored(t_manifest)
    if after == before:
        raise SystemExit("BUG: --write hat die Pruefsumme trotz geaenderter Datei nicht nachgezogen")
    if stored(t_release) != after:
        raise SystemExit("BUG: release.lua traegt nach --write eine andere Pruefsumme als manifest.lua")
    if after != expected_digest(t_manifest.read_text(encoding="utf-8")):
        raise SystemExit("BUG: die neue Pruefsumme passt nicht zu den Eintraegen")
    result = run(tmp_path, "--check")
    if result.returncode != 0:
        raise SystemExit(f"BUG: --check nach --write nicht sauber:\n{result.stdout}")

    # 3. Veraltete Pruefsumme
    text = t_release.read_text(encoding="utf-8")
    t_release.write_text(DIGEST_RE.sub('payload_digest = "00000000"', text, count=1), encoding="utf-8")
    result = run(tmp_path, "--check")
    if result.returncode == 0 or "payload_digest" not in result.stdout:
        raise SystemExit(f"BUG: --check erkennt eine veraltete Pruefsumme in release.lua nicht:\n{result.stdout}")

print("manifest_payload_digest_test.py: ok")
