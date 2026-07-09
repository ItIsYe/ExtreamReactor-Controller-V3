# Testplan (aktueller Stand — v358)

## Install/Update (aktualisiert: monolithischer Installer, Delete+Reinstall statt Stage/Backup)
1. **Fresh Install (lokal)**: `wget .../beta/installer` + `installer` starten, Rolle wählen, Abschluss prüfen (Dateianzahl + Reboot im Installer-Log).
   - Der Installer ist ein einziges Root-Skript; es bootstrappt die `installer/*.lua`-Module selbst aus eingebetteten Long-Strings — kein separates `installer_main.lua` mehr nötig.
2. **Reinstall (lokal)**: `installer` erneut starten; Rolle wird aus `/xreactor/config/role.lua` erkannt und vorgeschlagen.
3. **role.lua-Erhalt bei Reinstall** *(neu, 2026-06-30)*: vor dem Löschen von `/xreactor` muss `role.lua` zwischengespeichert und danach sofort wiederhergestellt werden — auch wenn der restliche Install-Vorgang danach fehlschlägt/abgebrochen wird, muss ein erneuter Installer-Lauf die Rolle noch kennen.
4. **Delete+Reinstall statt Stage/Backup** *(geändert, 2026-06-30)*: der alte Stage/Backup/Activate-Mechanismus (`/xreactor_stage`, `/xreactor_backup_prev`) existiert nicht mehr. `/xreactor` wird komplett gelöscht und direkt neu beschrieben. Test: bei großen Rollen (MASTER, RT) darf während der Installation kein doppelter Speicherplatzbedarf (alt+neu gleichzeitig) entstehen.
5. **Startup-Verhalten**: `/startup` wird vom Installer geschrieben (XReactor-Boot-Eintrag).
6. **Manifest-Vollständigkeit pro Rolle** *(neu, 2026-06-30)*: für jede Rolle inkl. LOG/LOG_COLLECTOR muss `files_for_role()` alle tatsächlich benötigten Dateien liefern — Regressionsfall: LOG erhielt durch eine fehlerhafte Bedingung (`if not is_log then`) lange Zeit nur ~11 Dateien ohne sein eigenes `nodes/log_collector/main.lua`. Bei jeder Änderung an `files_for_role()` Dateianzahl pro Rolle gegenprüfen.
7. **size_bytes-Konsistenz im Manifest** *(neu, 2026-06-30)*: Installer bricht mit `size mismatch` ab, wenn `manifest.lua`-`size_bytes` nicht zur tatsächlichen Dateigröße auf GitHub passt. Bei jeder Änderung einer manifestierten Datei muss `size_bytes` mitgezogen werden, sonst schlägt die Installation für alle Nodes fehl, die diese Datei brauchen.
8. **Auto-Update-Loop** *(neu, 2026-06-30)*:
   - Läuft als zweiter Thread in `parallel.waitForAny(node_thread, auto_update_loop)` auf jedem Node, inkl. RT.
   - Erster Check nach 30s, danach alle 120s.
   - Versions-Bump in `manifest.lua`+`release.lua` muss innerhalb des nächsten Intervalls einen automatischen Download+Reinstall+Reboot auf allen betroffenen Nodes auslösen.
   - **Regressionsfall RT**: `resolve_sha()` (Zusatz-Call gegen `api.github.com`) konnte den Async-HTTP-Wait in `parallel`-Coroutinen auf event-intensiven Nodes (RT) zum Hängen bringen (`Versuch 1/3` ohne Folge-Log). Fix: kein `api.github.com`-Call mehr im Update-Check-Pfad, nur noch direkte `raw.githubusercontent.com/.../beta/...`-Fetches. Bei jeder Änderung an `auto_update.lua` erneut auf allen Rollen (insb. RT) gegentesten, nicht nur auf ENERGY/LOG.
   - `shell.run()` darf in `auto_update.lua` und im `dofile(entry)`-Aufruf in `start.lua` nicht verwendet werden (nicht verfügbar in `parallel`-Coroutinen) — Regressionsfall führte zu `attempt to index global 'shell' (a nil value)` bzw. `No such program`.
9. **Manifest/Remote-Konsistenz vor Rollout**:
   - `python3 scripts/manifest_sync.py` muss `Consistency: OK` liefern.
   - Nach Publish muss `python3 scripts/verify_remote_manifest.py --base-url <published-xreactor-url> --check-local --expected-manifest xreactor/manifest.lua --require-path shared/build_info.lua` grün sein.
   - Damit werden sowohl Dateiinhalte (hash/size) als auch der veröffentlichte Manifest-Stand gegen den lokalen Release-Kandidaten geprüft.
9. **Beta-only Release-Quelle für Installer (aktueller Ist-Stand)**:
   - `xreactor/release.lua` bleibt auf `commit_sha = "beta"` und `source_ref = "beta"` (kein immutable Commit-Pin im Standardpfad).
   - `xreactor/manifest.lua` muss ebenfalls `source_ref = "beta"` führen; Release- und Manifest-Quelle dürfen nicht auseinanderlaufen.
   - Installer-Policy, `MIGRATION.md` und Release-Metadaten müssen dieselbe beta-only-Strategie abbilden (keine Mischstrategie, kein verdecktes Pinning).

## Node-ID / Identity
1. Persistierte `/xreactor/config/node_id.txt` muss immer Vorrang gegenüber Rollen-Defaults in Config haben.
2. Rollen-Default-ID (`RT-1`, `ENERGY-1`, etc.) darf bei Erststart keine effektive Runtime-ID-Kollision erzwingen.
3. Ohne persistierte ID muss deterministisch eine lokale Maschinen-ID erzeugt und gespeichert werden.

## ENERGY Single-Device-Modell + MASTER Aggregation
1. ENERGY bindet pro Node max. eine Matrix + max. einen Storage, auch wenn mehrere Kandidaten verfügbar sind.
2. MASTER aggregiert Energie-Gesamtsummen aus mehreren ENERGY-Nodes (stored/capacity/input/output).

## Safety (RT)
1. **Coolant Pending statt sofort SAFE**: Low-Coolant auslösen -> Log enthält `COOLANT_LOW_PENDING`, aber noch kein sofortiger SAFE/SCRAM.
2. **Bestätigter Coolant-Low-Fall**: Coolant-Low > ~4s halten -> SAFE mit Grund `SAFETY_COOLANT_LOW` und zugehöriger Safety-Ownership-Log.
3. **Pending-Recovery-Abbruch**: während Pending erholt sich Coolant wieder -> Pending wird als Recovery-Fall abgebrochen, kein SAFE-Übergang.
4. **Temperatur-Safety getrennt prüfen**: Übertemperatur triggert SAFE mit `SAFETY_TEMPERATURE_HIGH` und eigener Ownership-Kausalkette.
5. **SAFE-/SCRAM-Ursachen klar lesbar**: Übergangslogs enthalten explizite Gründe (`Entering SAFE mode reason=...`, SCRAM-Ownership-Logs).

## RT-/Turbinenregelung
1. **Alle gebundenen Turbinen werden pro Zyklus bewertet**: bei Multi-Turbinen-Setup (inkl. großem Satz, z. B. 25 im Discovery-/Snapshot-Test) pro Turbine Regelungs-/Diagnoselog prüfen.
2. **Overspeed-Bremse**: bei Overspeed muss `OVERSPEED_BRAKE` aktiv werden, Soll-Flow auf `0` gesetzt werden und Coil-Bremsung erzwungen werden.
3. **Target-Band mit aktiver Trim-Logik**: in-band Zustände prüfen (`TARGET_TRIM_UP`, `TARGET_TRIM_DOWN`, `HOLDING_TARGET_ACTIVE`).
4. **Readback-Lag-Diagnose**: bei Soll/Ist-Mismatch müssen `READBACK_LAG`/Pending-Klassifikationen und kombinierte Zustände wie `ACTIVE_TRIM_WITH_READBACK_LAG` erscheinen.
5. **Flow-0-Pending bei Overspeed**: wenn Overspeed aktiv und Readback nicht sofort folgt, muss der Pending-Pfad mit klarer Diagnose (inkl. retries/detail) sichtbar sein.
6. **Lua-Parse-Guard (RT Main)**: `tests/rt_main_parse_guard_test.py` muss grün sein, damit lokale Variablen-/Register-Limits in `nodes/rt/main.lua` frühzeitig auffallen.
7. **Rod-Regler Min-Clamp / 20%-Power-Cap**: Default prüfen (`autonom.regulator_min_rods = 80`); Automatik darf nie unter `80` rods gehen (`100% rods = 0% Leistung`, `0% rods = 100% Leistung`), Log muss `ROD_TARGET_CLAMPED_BY_CONFIG_MIN` zeigen.
8. **Rod-Regler Max-Clamp**: `autonom.regulator_max_rods` < aktuellem Ziel setzen; Automatik darf Ziel nicht darüber schreiben, Log muss `ROD_TARGET_CLAMPED_BY_CONFIG_MAX` zeigen.
9. **Rod-Regler Min/Max-Kombination**: gültigen Bereich setzen (z. B. 40..85) und verifizieren, dass Automatik innerhalb des Bereichs bleibt; bei invertierter Eingabe (`min > max`) nach Normalisierung konsistenten Bereich prüfen.
10. **Safety übersteuert Rod-Config**: SAFE/SCRAM auslösen und verifizieren, dass Rods weiterhin auf `100%` gefahren werden können (Config-Clamps dürfen Safety nicht blockieren).
11. **Interner Steam-Guard (Sekundärsignal)**: Primärregelung via Turbinenbedarf aktiv lassen; bei hohem internem Reaktor-Steam muss weiteres Öffnen blockiert werden (`steam_guard_block_open=true`), bei kritischem Füllstand zusätzlich kontrolliertes Schließen (`steam_guard_force_close=true`).
12. **Steam-Guard-Hysterese/Stabilität**: Schwellenbereich durchfahren und prüfen, dass Guard erst an `high_ratio`/`critical_ratio` aktiviert, erst an `high_release_ratio`/`critical_release_ratio` wieder freigibt (kein unnötiges Hin-und-her-Regeln).

## Kommunikation / Discovery / Betrieb
1. **ACK/Retry**: Retry + ACK für `COMMAND` prüfen; `STATUS`/`HEARTBEAT` bleiben ohne Applied-ACK-Logik.
2. **Modem-Auswahl**: Override + Autodetect-Fallback testen (inkl. klarer Warnungen bei ungültigem Override).
3. **Registry-Stabilität**: unveränderte Discovery-Zyklen erzeugen keine unnötigen Registry-Rewrites.
4. **Health/Degraded**: fehlende Kernperipherie führt zu DEGRADED mit nachvollziehbaren Reasons.
5. **ENERGY Scope-Guard (`is_master_connected` / `master_peer_state`)**: `tests/energy_scope_regression_test.py` (und optional `tests/energy_master_connection_scope_regression_test.lua`) muss grün sein, damit `build_status_payload`/UI keinen Nil-Call durch lokale Funktionsreihenfolge erzeugen.
6. **ENERGY Induction-Komponentenpfad**:
   - `tests/induction_matrix_component_counts_test.lua` prüft die Normalisierung von Matrix-Komponentenzahlen über API-Varianten (`table`/`string`/`number`), Multi-Return-Payloads, Nil-Readiness-Signale und den Ports-Fallback.
   - `tests/energy_matrix_component_logging_regression_test.lua` schützt vor Ports-bedingter Fehlklassifikation, stellt die Reason-Klassifikation (`api_variant`/`temporary_not_ready`) sicher und verhindert wiederholten identischen Log-Spam.
7. **ENERGY Matrix-Metrik-Cache/Slowdown-Diagnose**:
   - `tests/energy_matrix_metric_poll_interval_config_test.lua` stellt sicher, dass `matrix_metric_poll_interval` in der ENERGY-Config vorhanden und gültig ist.
   - `tests/energy_matrix_payload_cache_regression_test.lua` schützt Matrix-Metrik-Cache und Slowdown-Diagnoselog (`Status payload slow matrix calls: ...`) gegen Regressionen.
   - `tests/energy_matrix_polling_pacing_regression_test.lua` schützt das kombinierte Call-/Zeitbudget sowie Heartbeat-Pump im Matrix-Poll-Loop gegen Regressionen.
   - `tests/induction_matrix_grouping_test.lua` schützt die Matrix-Gruppierung gegen falsches Prefix-Collapsing: ohne stabile API-Identität bleibt jeder Port eine eigene Matrix; mit stabiler Matrix-ID werden Ports korrekt zusammengeführt.
8. **ENERGY Architektur-Stabilität (4-Matrix-Last)**:
   - `tests/energy_architecture_stability_regression_test.lua` schützt die dauerhafte Trennung der Schichten: persistente Matrix-Identität, Topology-gated Cache-Invalidierung, dedizierter Storage-Sampling-Service und last-good Snapshot-Weitergabe.
   - Unter Last prüfen, dass `DISCOVERY` keine zyklischen Voll-Invalidierungen auslöst, `MATRIX_SAMPLE` Komponentencalls budgetiert bleiben und Heartbeats weiterhin in konstantem Intervall gehen.
   - HEALTH/Reasons dürfen bei verzögertem Sampling nicht sofort auf `NO_MATRIX`/`NO_STORAGE` kippen, solange last-good Snapshot + bekannte Bindings vorliegen.
9. **Support-Node Shared Discovery-Pfad**:
   - `tests/support_nodes_shared_runtime_regression_test.py` muss grün sein und die Nutzung von `collect_devices_by_methods` in `fuel`/`water`/`reprocessor` absichern.
   - Dadurch bleibt die Discovery-Klassifikation außerhalb von RT zentral konsistent, ohne rollenspezifische Fachlogik zu verlieren.
10. **Manifest-Entrypoint-Coverage (Installer-Schutz gegen fehlende Module)**:
   - `python3 tests/manifest_entrypoint_require_coverage_test.py` muss grün sein.
   - Der Guard prüft für `MASTER`/`ENERGY`/`WATER`/`FUEL`/`REPROCESSING`, dass direkte `require(...)`-Module aus den Rollen-Entrypoints im installierten Expected-Set aus `manifest.lua` enthalten sind.
   - Für MASTER ist `master.rt_sync_coalescer` explizit als Pflichtfall abgesichert: wenn das Modul im Entrypoint genutzt wird, aber nicht im MASTER-Manifest enthalten ist, muss der Guard hart fehlschlagen.
11. **MASTER Presence-/Identity-/RT-Hold Guards**:
   - `tests/master_message_handler_node_id_canonicalization_test.lua` stellt sicher, dass STATUS mit kanonischer `node_id` alte Sender-IDs (z. B. `ENERGY-1`) in den MASTER-Nodes sauber ersetzt.
   - `tests/comms_peer_retention_cleanup_test.lua` stellt sicher, dass langzeitig down/stale Peers aus dem Peer-State auslaufen (kein permanenter Altzustand).
   - `tests/master_ui_controller_rt_hold_toggle_test.lua` stellt sicher, dass die zentrale RT-OFF-Hold-Aktion im MASTER umschaltbar ist.
   - `tests/rt_sync_global_off_hold_test.lua` stellt sicher, dass RT-OFF-Hold Setpoints auf `0` erzwingt.
12. **ENERGY Sampling-Last Guard (Single-Matrix)**:
   - `tests/energy_matrix_single_group_budget_regression_test.lua` schützt, dass im Single-Matrix-Modell kein künstliches per-matrix Backlog/Throttle durch zu enges Budget entsteht.

13. **Manifest-Drift Repo-Guard (geänderte manifestierte Dateien)**:
   - `python3 tests/manifest_changed_files_guard_test.py` muss grün sein.
   - Wenn manifestierte Dateien (z. B. `xreactor/master/main.lua`) geändert wurden, muss `xreactor/manifest.lua` im selben Change mitgeführt werden, sonst harter Fail.

## First start / bootstrap / role setup
1. **Erststart nach Install**: `/xreactor/start.lua` liest Rolle aus `/xreactor/config/role.lua` und startet genau die passende Runtime.
2. **Rollenwechsel**: erfolgt nicht im Update-Dialog; Rollenwechsel nur über Neuinstallation oder manuelle, bewusste Re-Konfiguration.
3. **Bootstrap-Basics**: Node kommt ohne historische Setup-Reste hoch; Logs dokumentieren erkannten Role-/Runtime-Startpfad.

## Finaler Akzeptanzlauf (Non-RT Abschluss)
1. **Architektur-Guard (Support-Nodes)**: `python3 tests/support_nodes_shared_runtime_regression_test.py`.
2. **ENERGY Scope-/Heartbeat-/Topologie-Regressionslauf**:
   - `python3 tests/energy_scope_regression_test.py`
   - `python3 tests/energy_heartbeat_decoupling_regression_test.py`
   - `python3 tests/energy_persistent_topology_regression_test.py`
3. **Parse-/Syntax-Guards**:
   - `python3 tests/cc_parse_guard_test.py`
   - `python3 tests/rt_main_parse_guard_test.py`
4. **Optional lokal mit Lua-Interpreter**: ausgewählte `.lua`-Regressionen für Installer/MASTER/ENERGY/Support ergänzend ausführen.
5. **Wichtig**: `tests/rt_main_structure_guard_test.py` ist ein RT-Größen-Guard und gehört in einen separaten RT-Audit-Track (kein Non-RT-Abschlusskriterium).

## Setpoint-Fluss (gelöst, 2026-06-30/07-01 — jetzt aktiv testen statt als unzuverlässig zu behandeln)
Zwei reale Bugs (siehe MIGRATION.md → "Historisch gelöste Probleme") wurden gefunden und behoben:
1. **capacity_max/capacity_ready Feld-Reihenfolge** in `populate_rt_status()` — Test: nach STATUS-Empfang muss `node.capacity_max`/`capacity_ready` den Stand aus dem GERADE eingetroffenen Payload zeigen, nicht den vorherigen.
2. **PEAK-Profil Basisleistung** — bei PEAK muss `estimate_base_power()` `learned_capacity_total` bevorzugen, nicht den aktuell gemessenen (ggf. gedrosselten) Output. Test: `power_target` soll nach einem Wechsel auf PEAK innerhalb der nächsten periodischen Neuberechnung (alle ~30s) Richtung gelernter Maximalkapazität steigen, nicht auf dem Stand zum Zeitpunkt des Profilwechsels einfrieren.

Bis ein dedizierter Regressionstest existiert, gilt: manuelle Verifikation über Master-Overview (`Soll` vs. `Ist` RF/t, sollten sich bei PEAK und ausreichender Kapazität annähern) nach jeder Änderung an `rt_sync.lua` oder `runtime_ops_profile.lua`.

## UI-Redesign (2026-07-07)
1. **layout.badge_row()** (`master/ui/layout.lua`): bei beliebig vielen/langen Badges darf die Gesamtbreite NIE die Monitorbreite überschreiten. Test: künstlich viele/lange Badge-Labels übergeben, prüfen dass Kürzung/Priorisierung greift statt Überlappung.
2. **Overview RT-Fleet-Summary**: `overview.rt_fleet_summary` muss `active`/`total`/`assignment`/`status` konsistent mit der echten RT-View zeigen (kein separater, potenziell abweichender Berechnungspfad).
3. **Ampel-Monitor Isolation**: absichtlicher Fehlertest — Ampel-Monitor abklemmen/entfernen während RT läuft, Hauptmonitor darf davon UNBEEINFLUSST bleiben (keine eingefrorene/verzerrte Anzeige). Ein früherer, ungetesteter erster Versuch dieses Features hatte genau das nicht sichergestellt und legte beim Fehlschlagen die komplette RT-Anzeige lahm.
4. **node.rt Merge statt Replace**: bei jedem STATUS-Tick müssen bereits vom UI-Layer in `node.rt` geschriebene Felder (z. B. `assignment_state`) erhalten bleiben, dürfen nicht durch das frische Payload komplett überschrieben werden.
5. **assigned_power/assigned_percent Persistenz**: `node.assigned_power` muss nach jedem `rt_sync.lua`-Durchlauf gesetzt sein für jeden Node im `active`-Array — Regressionsfall zeigte 0.0 auf jeder RT-Card trotz korrektem globalen Soll.

## Turbinen-Log-Rate-Limiting (2026-07-07)
"Overspeed brake pending" darf max. 1x pro 5s pro Turbine geloggt werden (`ctrl.last_overspeed_log_ms`). Regressionsfall: ungedrosselte Warnung flutete den Log-Ringpuffer (nur 1000 Zeilen) komplett innerhalb weniger Sekunden und verdrängte andere, wichtigere Log-Einträge (SET_SETPOINTS, ReactorCtrl-Änderungen).

## Repo-Hygiene (2026-07-07)
9 Tests für den mittlerweile ersetzten Stage-basierten Installer-Mechanismus (`tests/installer_stage_install_behavior_test.lua` und weitere, die direkt `xreactor/installer_main.lua`/`installer_stage.lua`/etc. vom Dateisystem lasen) wurden zusammen mit den referenzierten toten Dateien gelöscht. `tests/master_shipped_lua_parse_guard_test.py` hatte eine tote Referenz auf `xreactor/installer_manifest.lua` und wurde auf die aktuelle Datei `xreactor/installer/manifest.lua` korrigiert statt gelöscht (der Test selbst — ein generischer Parse-/Patch-Artefakt-Guard über das gesamte `xreactor/`-Verzeichnis — bleibt wertvoll). `tools/offline_validate.lua` (läuft in der CI bei jedem Push) hatte einen `required`-Dateien-Check, der die 6 gelöschten Dateien weiterhin als Pflicht voraussetzte und bei jedem folgenden Lauf fehlgeschlagen wäre — korrigiert.

## Audit-Protokoll (2026-04-27)

Durchgeführter Code-/Funktionsaudit mit Fokus auf Fehlererkennung bei unverändertem Laufzeitverhalten:

1. Erfolgreich ausgeführt:
   - `python3 tests/cc_parse_guard_test.py`
   - `python3 tests/rt_main_parse_guard_test.py`
   - `python3 tests/energy_scope_regression_test.py`
   - `python3 tests/energy_persistent_topology_regression_test.py`
   - `python3 tests/manifest_entrypoint_require_coverage_test.py`
2. Ergebnis:
   - Alle oben genannten Guards liefen erfolgreich durch.
   - Keine regressionsrelevanten Codefehler im geprüften Scope festgestellt.
3. Bekannte Umgebungsgrenze im Audit-Container:
   - Lua-Interpreter (`lua`) ist nicht installiert; direkte `.lua`-Regressionstests konnten hier nicht ausgeführt werden und müssen in einer CC-/Lua-fähigen Umgebung nachgezogen werden.
