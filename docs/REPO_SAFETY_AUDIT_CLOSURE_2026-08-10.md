# Repo-Safety-Audit – Abschlussnachweis

Stand: 2026-08-10

Zielbranch: `beta`

Basis: `fd26894cd744f93cf66d333de7e5bd44ec24c2be` (`beta-v512`)

Geprüfter Runtime-Code-Head: `0cc0efd575aab082a361a4cf96f600aa6086f46f` (`beta-v521`)

Pull Request: [#504](https://github.com/ItIsYe/ExtreamReactor-Controller-V3/pull/504)

## Urteil

Die codeseitigen Findings des Repo-Safety-Audits sind im Draft-PR #504 umgesetzt und automatisiert abgedeckt. Der Stand ist **code-complete, aber noch nicht ingame-abgenommen**.

Der PR darf erst auf „Ready for review“ gesetzt beziehungsweise gemergt werden, wenn die manuelle Hardware-Abnahme am Ende dieses Dokuments protokolliert ist. Ein grüner Headless-Lauf ersetzt diese Abnahme nicht.

## Statusdefinitionen

- **BEHOBEN**: Produktionscode geändert und durch mindestens einen Regressionstest abgesichert.
- **VERIFIZIERT**: relevante automatisierte Suite am exakten PR-Head erfolgreich.
- **INGAME OFFEN**: Verhalten hängt von echten CC:Tweaked-/Mod-Peripherien, Funk, Reboot oder physischer Topologie ab.

## Audit-Traceability

| Bereich / Finding | Wesentliche Umsetzung | Nachweis | Status |
|---|---|---|---|
| Shared Utils: öffentliche Helper beim ersten `require()` verfügbar | Initialisierungsreihenfolge in `core/utils.lua` korrigiert | `utils_public_helpers_init_order_test.lua` | BEHOBEN |
| COMMS: ACK muss zur Zielidentität gehören | ACK-Quelle und -Ziel werden gegen den Inflight-Eintrag geprüft | `comms_ack_identity_regression_test.lua` | BEHOBEN |
| Protocol: fehlende Identität/Version/IDs dürfen nicht fail-open werden | Remote-Absender wird nicht lokal synthetisiert; `proto_ver`, `message_id` und `ack_for` werden strikt validiert | `protocol_fail_closed_validation_test.lua`, `protocol_missing_sender_fails_closed_test.lua` | BEHOBEN |
| Command Trust Boundary | Node-Kommandos nur von Rolle `MASTER`, optional zusätzlich an `trusted_master_id` gebunden | `comms_command_source_authorization_test.lua` | BEHOBEN |
| Installer: unveränderliche Source pro Lauf | Bootstrap, Release, Manifest und Dateien werden an denselben aufgelösten Commit-SHA gebunden | `installer_recovery_commit_guard_test.lua`, `installer_resolved_commit_metadata_test.lua` | BEHOBEN |
| Installer: Configbackup vollständig oder Abbruch | Listing-, Open-, Read- und Closefehler brechen vor dem ersten destruktiven Schritt ab; Pfadmenge und Bytes werden verifiziert | `installer_config_backup_fail_closed_test.lua` | BEHOBEN |
| Installer: generische Stage-Recovery | `.xr_tmp` nur nach Größe/CRC32 übernehmen; `.xr_prev` konservativ wiederherstellen; vollständige erwartete Dateiliste prüfen | `start_generic_stage_recovery_test.lua`, `start_lua_incomplete_install_blocks_role_test.lua` | BEHOBEN |
| Installer: transaktionssichere lokale Configwrites | Serialisieren vor Änderung, Tempwrite, Readback, Backup, Commit, Verifikation und Rollback | `utils_write_config_atomic_rollback_test.lua` | BEHOBEN |
| Installer: installierter Commit sichtbar | Lokale `install_meta.lua` enthält aufgelösten SHA, Installationszeit, Manifest und Recovery-Ursprung; Bootausgabe zeigt den SHA | `installer_resolved_commit_metadata_test.lua` | BEHOBEN |
| Managed Remote Update | Funk-/Redstone-Kommandos werden in den gemeinsamen Updater eingereiht; kein Installerstart im Rollen-Eventhandler | `remote_update_managed_queue_test.lua`, `remote_update_shell_result_guard_test.lua` | BEHOBEN |
| Quiesce-Handschlag fail-closed | Nur explizites `true` bestätigt sichere Ausgänge; fehlender Callback, `nil`, `false` oder Fehler stoppen den Übergang | `support_runtime_quiesce_test.lua`, `install_p0_2_quiesce_wiring_test.lua` | BEHOBEN |
| FUEL/REPROCESSOR: Wireless-VALVEs vor Update bestätigt blockieren | Eigener Quiesce-Zustand wartet auf aktuelle Command-ID-gebundene BLOCKED-ACKs und hält Retry aktiv | `redstone_router_quiesce_ack_gate_test.lua`, `fuel_reprocessor_quiesce_ack_wiring_test.lua` | BEHOBEN / INGAME OFFEN |
| Routing: Final-Block-Fehler latchen | Terminale Safety-Phasen bleiben sichtbar und blockieren neue Lieferungen bis BLOCKED bestätigt ist | `redstone_router_final_block_latch_test.lua` | BEHOBEN / INGAME OFFEN |
| FUEL: Async-Lieferung eindeutig binden | Stabiler Transaction-Record und explizite Phasen bis zum bestätigten Final-Block | `fuel_logistics_async_delivery_lifecycle_test.lua`, `redstone_router_refresh_transaction_race_test.lua` | BEHOBEN |
| FUEL: unsichere oder mehrdeutige Reaktorrouten fail-closed | Node-scoped Reaktoridentitäten, Kollisionsschutz und strikte Produktionsconfig | `fuel_status_identity_validation_test.lua`, `fuel_config_fail_closed_test.lua` | BEHOBEN / INGAME OFFEN |
| RT: bestätigter Update-Safe-State | Startup abbrechen, alle Rods sicher schreiben und vollständig zurücklesen, Reaktoren deaktivieren, Turbinenflow/Coil/Zustand bestätigen | `rt_update_quiesce_hardware_confirmation_test.lua`, `reactor_update_quiesce_all_rods_test.lua` | BEHOBEN / INGAME OFFEN |
| RT: Hardwarewrite-Wahrheit | Teilweise Rodwrites sowie nur gemittelte Readbacks gelten nicht als sicher; Induktorstatus erst nach bestätigtem Write | `reactor_update_quiesce_all_rods_test.lua`, `rt_inductor_confirmed_state_regression_test.lua` | BEHOBEN / INGAME OFFEN |
| RT: Kapazität an Topologie binden | Topologiesignatur/-generation wird persistiert; Add/Remove/Rename invalidiert den alten Maximalwert | `rt_capacity_topology_invalidation_test.lua`, `rt_capacity_cache_persistence_regression_test.lua` | BEHOBEN |
| VALVE: Pairing erst nach Validierung, Apply und Persistenz | Ungültiges Erstpaket kann Trust nicht setzen; Persistenzfehler rollt auf physisch BLOCKED zurück | `valve_pair_after_apply_persistence_guard_test.lua`, `valve_sender_pairing_and_sorter_reconnect_test.lua` | BEHOBEN / INGAME OFFEN |
| VALVE: physische Safety statt RAM-Annahme | Quiesce, Failsafe, Reconnect und Duplicate-ACK erzwingen frischen Sorter-Write und soweit verfügbar Readback | `valve_failed_write_retry_test.lua`, `valve_safety_regression_test.py` | BEHOBEN / INGAME OFFEN |
| MASTER: persistente Sollwerte ehrlich bestätigen | `APPLIED_PERSISTED`, `APPLIED_VOLATILE`, `REJECTED` und `TIMEOUT`; `confirmed_value` nur nach `persisted=true` aller Ziele | `master_config_edits_test.lua`, `master_config_edit_ack_wiring_test.lua`, `fuel_reserve_persistence_ack_test.lua` | BEHOBEN |
| MASTER: stale RT-Kapazität nicht weiterverwenden | Offline-/stale Kapazität wird aus Profilbasis ausgeschlossen und sticky `capacity_ready` gelöscht | `master_profile_stale_capacity_test.lua`, `master_auto_profile_stale_energy_guard_test.lua` | BEHOBEN |
| ENERGY: Last-Good ist nicht automatisch frisch | Attempt- und Last-Good-Zeit getrennt; Lesefehler altern zu `STALE`; Capacityfehler nehmen an Backoff teil | `energy_failed_reads_stay_stale_test.lua`, `energy_stale_last_good_regression_test.lua` | BEHOBEN / INGAME OFFEN |
| ME-Bridge-Discovery | Mitgelieferte Konventionsnamen dürfen auf generierte Peripheralnamen zurückfallen; explizite Customnamen bleiben strikt | `fuel_logistics_me_bridge_discovery_by_methods_test.lua`, `reprocessor_me_bridge_default_fallback_test.lua` | BEHOBEN / INGAME OFFEN |
| UI: Monitoridentität und atomarer Frame | Fremde Touches werden konsumiert; physische Monitore erhalten einen gemeinsamen Window-Backbuffer ohne FUEL doppelt zu puffern | `ui_router_monitor_identity_test.lua`, `ui_router_shared_window_backbuffer_test.lua` | BEHOBEN / INGAME OFFEN |
| Regression-Ausschlüsse | Veraltete Exclusions einzeln geprüft und entweder repariert oder an den aktuellen Vertrag angepasst | Skip-Policy: `0` Lua, `0` Python | VERIFIZIERT |

## Automatisierter Nachweis am PR-Head

- Offline CI: erfolgreich
  - Repository-Integrität
  - Lua-Syntax
  - Manifest & Release
  - Versions-Bump-Guard
  - Skip-Policy
  - 261 Lua-Tests, 0 fehlgeschlagen, 0 ausgeschlossen
  - 30 Python-Tests, 0 fehlgeschlagen, 0 ausgeschlossen
- Deployment Gate: erfolgreich
  - strikte Manifest-/Release-Integrität
  - Versionsmonotonie
  - Szenarien-, Property-, Chaos- und Mutationstests
- `manifest-v521` / `beta-v521`, 174 Runtime-Dateien

## Verbindliche Ingame-Abnahme vor Merge

- [ ] RT mit echtem Mehrstab-Reaktor: Update-Quiesce lässt jeden Rod vollständig eingefahren und den Reaktor inaktiv.
- [ ] VALVE: externer Sorter-Reset, Reconnect, Duplicate-Kommando und Update-Quiesce enden physisch BLOCKED.
- [ ] FUEL mit mindestens zwei RT-Nodes: node-scoped Reaktoridentitäten wählen das richtige Ziel; Legacy-ID-Kollision liefert nichts aus.
- [ ] ENERGY: Disconnect und Lesefehler altern sichtbar von Last-Good/Degraded zu `STALE` und werden vom MASTER nicht als frisch verwendet.
- [ ] Remote Update mit Arming/Token: Quiesce, Rollenstopp, Installation und Reboot funktionieren; ein Fehler nach Quiesce wird per Reboot sicher wiederhergestellt.
- [ ] Getrennte Haupt-/Statusmonitore: Touches auf dem falschen Monitor navigieren und editieren nicht.
- [ ] Monitor Resize/Detach/Reconnect und FUEL-Backbuffer zeigen kein Flackern und verlieren keine Eingaben.

## Merge-Regel

1. Hardware-Abnahme oben mit Datum, Aufbau und Ergebnis ergänzen.
2. Mindestens ein unabhängiges Review durchführen.
3. PR von Draft auf „Ready for review“ setzen.
4. Alle Workflows auf dem unveränderten finalen Head erneut erfolgreich ausführen.
