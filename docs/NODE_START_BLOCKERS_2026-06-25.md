# Node Start Blockers — ERLEDIGT

> Letzte Aktualisierung: **2026-07-01**, `beta-v261`
> Status: **Alle Punkte behoben.**

---

## Punkt 4 — role.lua ging bei Auto-Update verloren ✓ BEHOBEN

Datei: `installer` (Root)

`role.lua` war nur im manuellen Installer-Codepfad in der PRESERVE-Liste, nicht im (weit häufiger durchlaufenen) Auto-Update-Reinstall-Codepfad. Jeder automatische Update-Zyklus löschte damit unbemerkt die Rollenzuordnung des Nodes — er bootete danach ohne Rolle. Beide Codepfade nutzen jetzt dieselbe PRESERVE-Liste (`config/node_id.txt`, `config/capacity_cache.lua`, `config/role.lua`). Behoben in v235 (2026-06-30).

## Punkt 5 — Log-Collector empfing nichts (Recv 0) ✓ BEHOBEN

Dateien: `xreactor/core/remote_log.lua`, `xreactor/shared/constants.lua`

Kanal-Mismatch: Sender nutzten fest `6502`, `shared/constants.lua` definiert den LOG-Kanal als `6503`. Beide Seiten laufen jetzt auf `6503`. Behoben in v234 (2026-06-30).

## Punkt 6 — Setpoint-Fluss fror auf zu niedrigem Wert ein ✓ BEHOBEN

Dateien: `xreactor/master/message_handlers.lua`, `xreactor/master/runtime_ops_profile.lua`, `xreactor/master/rt_sync.lua`

Zwei getrennte Bugs: (a) Feld-Reihenfolge-Fehler ließ `node.capacity_max`/`capacity_ready` immer einen STATUS-Zyklus veraltet erscheinen; (b) die PEAK-Profil-Berechnung bevorzugte den aktuell gemessenen (ggf. gedrosselten) Output statt der gelernten Maximalkapazität, wodurch `power_target` beim Profilwechsel auf einem alten, niedrigen Snapshot einfror. Zusätzlich wurden die berechneten `assigned_power`/`assigned_percent`-Werte nie persistent auf das Node-Objekt geschrieben (nur lokal, verworfen) — die Master-UI zeigte deshalb dauerhaft `Soll 0.0` pro RT-Node trotz korrektem globalen Wert. Alle drei Teile behoben v229–v236 (2026-06-30/07-01).

## Punkt 7 — UI-Badges liefen ineinander, Werte fehlten/waren doppelt ✓ BEHOBEN

Dateien: `xreactor/master/ui_controller.lua`, `xreactor/master/ui/multiview.lua`, `xreactor/master/ui/layout.lua` (neu), `xreactor/master/ui/rt_dashboard.lua`, `xreactor/nodes/rt/monitor_ui.lua`

Mehrere unabhängige Ursachen für wiederholte UI-Symptome: `node.rt` wurde bei jedem STATUS-Tick komplett ersetzt statt gemerged (verwarf vom UI gesetzte Felder wie `assignment_state`/`control_source` — "Sticky-Falle"); Badge-Leisten hatten keine zentrale Breitenberechnung und liefen auf schmalen Monitoren ineinander; die RT-Node-eigene Turbinen-Zeile erschien während Capacity-Learning doppelt. Neues `layout.lua`-Modul löst das Badge-Problem strukturell (garantierte Passform statt Ad-hoc-Rendering pro View). Behoben v243–v261 (2026-07-01), inkl. einem neuen 1×3-Ampel-Statusmonitor als optionales Feature.

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
