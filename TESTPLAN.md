# Testplan (aktueller Stand)

## Install/Update
1. **Fresh Install (lokal)**: `installer` starten, Rolle wählen, Abschluss prüfen (`Installation complete` im Installer-Log).
2. **Update (lokal)**: `installer` -> `Update`; Rolle wird aus `/xreactor/config/role.lua` übernommen.
3. **Storage-Preflight**: im Installer-Log müssen Free/Payload/Growth/Stage-Peak/Buffer-Werte protokolliert werden; bei Low-Space sauberer Abbruch mit konkreter Meldung.
4. **Stage/Backup/Activation/Commit**:
   - Stage-Aufbau in `/xreactor_stage`
   - Aktivbestand nach `/xreactor_backup_prev`
   - Activate: Stage-Aktivierung auf `/xreactor`
   - Backup-Entfernung nach erfolgreichem Commit.
5. **Startup-Verhalten**: `/startup` wird nur überschrieben, wenn es als XReactor-Startup erkannt wird; fremde Startups bleiben erhalten.
6. **Config-Erhalt beim Update**: bestehende `/xreactor/config/*` bleibt wirksam (durch Copy nach Stage).

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
   - `tests/induction_matrix_grouping_test.lua` schützt die Matrix-Gruppierung gegen falsches Prefix-Collapsing: ohne stabile API-Identität bleibt jeder Port eine eigene Matrix; mit stabiler Matrix-ID werden Ports korrekt zusammengeführt.

## First start / bootstrap / role setup
1. **Erststart nach Install**: `/xreactor/start.lua` liest Rolle aus `/xreactor/config/role.lua` und startet genau die passende Runtime.
2. **Rollenwechsel**: erfolgt nicht im Update-Dialog; Rollenwechsel nur über Neuinstallation oder manuelle, bewusste Re-Konfiguration.
3. **Bootstrap-Basics**: Node kommt ohne historische Setup-Reste hoch; Logs dokumentieren erkannten Role-/Runtime-Startpfad.
