# Node Start Blockers — ERLEDIGT

> Letzte Aktualisierung: **2026-07-01**, `beta-v241`
> Status: **Alle Punkte behoben.**

---

## Punkt 1 — RT Parse-/Syntax-Blocker (fehlendes Komma) ✓ BEHOBEN

Datei: `xreactor/nodes/rt/main.lua`

Das fehlende Komma nach `build_health_payload = function() ... end` wurde im Rahmen
der RT monitor_ui.update()-Überarbeitung (2026-07-01) korrekt gesetzt.
RT startet sauber.

## Punkt 2 — Veraltete hardkodierte Build-Werte ✓ BEHOBEN

Datei: `xreactor/nodes/rt/main.lua`

`manifest_id = "manifest-v158"` und `release_id = "beta-v158"` waren fest kodiert.
Jetzt werden beide Werte dynamisch aus `/xreactor/release.lua` geladen — zeigt
immer den aktuell installierten Stand, kein manuelles Nachpflegen nötig.
Behoben in v241 (2026-07-01).

## Punkt 3 — `hash_algo = "none"` im Manifest ✓ BEHOBEN

Datei: `xreactor/manifest.lua`

Alle 143 Manifest-Einträge wurden mit korrekten `size_bytes` und CRC32-Hashes
regeneriert (`tools/regenerate_manifest_metadata.py`). `hash_algo` ist wieder
`"crc32"`. Behoben in v240 (2026-07-01).
