# XReactor Controller V3

SCADA-ähnlicher Steuerungs-Stack für Minecraft mit **CC:Tweaked**, **Extreme Reactors** und optional **Mekanism** (Energiespeicher/Fluids). Der Stack besteht aus einem MASTER, der Telemetrie sammelt, Sequenzen orchestriert und Visualisierung liefert, sowie spezialisierten Nodes, die lokale Peripherals steuern.

## Projektziel & Überblick
- **MASTER** sammelt Statusdaten, koordiniert RT-Nodes (Reactor/Turbine) und verteilt Setpoints.
- **Nodes** kapseln die lokale Peripherie-Steuerung und Sicherheitslogik.
- **RT-Node** läuft autonom weiter, wenn der MASTER nicht erreichbar ist.

## Unterstützte Versionen / Mods
- Minecraft 1.21
- **CC:Tweaked** (ComputerCraft)
- **Extreme Reactors** (Reaktoren/Turbinen)
- **Mekanism** (optional, Energy Cubes/Induction Matrix)
- **Applied Energistics 2** (optional, Fuel-Storage)

## Architektur (Kurz)
```
MASTER (Wireless Modem)
  ├─ Multi-Monitor UI (wired)
  └─ Sequencer/Setpoints
        │
        ▼
Wireless Modem (Control/Status)
        │
        ├─ RT-NODE (Reactor/Turbine)
        ├─ ENERGY-NODE (Mekanism Telemetrie)
        ├─ WATER-NODE (Kreislauf/Buffer)
        ├─ FUEL-NODE (Fuel-Reserve/AE2)
        └─ REPROCESSOR-NODE (Waste/Output)
```

## Rollen & Aufgaben
- **MASTER**: Aggregiert Status, startet Sequenzen, verteilt Setpoints, rendert UI.
- **RT-NODE**: Steuert Reaktoren/Turbinen, lokalen Schutz (SCRAM/Flow-Limits), Moduswechsel (AUTONOM/MASTER/SAFE).
- **ENERGY-NODE**: Liest Energie-Speicherstände/IO-Raten.
- **FUEL-NODE**: Überwacht Fuel-Reserven (z. B. AE2), berichtet Engpässe.
- **WATER-NODE**: Stabilisiert Wasser-/Dampfkreislauf.
- **REPROCESSOR-NODE**: Überwacht Waste-Reprocessing.

## Netzwerk-Setup
- **Wireless Modem**: Kommunikation MASTER ↔ Nodes (Control/Status, Kanäle 6500/6501).
- **Wired Modem**: MASTER zu Monitoren, Nodes zu lokalen Maschinen.
- **Protokoll**: `proto_ver = 1.0` (bei Mismatch ignorieren Nodes/Master die Nachricht).
- **Protokoll-Versionierung**: `proto_ver` nutzt `major.minor` (z. B. `1.0`). Gleiche Major-Versionen sind kompatibel, Minor-Abweichungen werden toleriert.
- **Wichtig**: Der MASTER greift **nie** direkt auf Peripherals zu – nur die Nodes tun das.
- **Comms-Layer**: Commands nutzen ACK/Retry/Timeout/Dedupe; Heartbeats/Status sind best-effort (Master erkennt Staleness).
- **2-Phase ACK**: Commands senden `delivered` ACK, optional `applied` ACK nach Ausführung.

## Comms Reliability
- **Envelope**: Jede Nachricht enthält `message_id`, `proto_ver`, `src`, `dst`, `type`, `payload`, `ts`.
- **ACK-Phasen**:
  - `ACK_DELIVERED` direkt nach Empfang eines COMMAND.
  - `ACK_APPLIED` nach Ausführung mit Ergebnis `{ ok, error?, module_id? }`.
- **Retry/Backoff**: COMMANDS werden mit Exponential-Backoff erneut gesendet, bis ACKs kommen oder `max_retries` erreicht sind.
- **Dedupe**: Pro Sender wird ein Zeitfenster gecacht, um doppelte COMMANDS zu erkennen.
- **COMMS_DOWN**: Ein Peer ist „down“, wenn `peer_timeout_s` überschritten wird (UI zeigt `COMMS_DOWN` + Age).

## Definition of Done (Comms)
- **Keine Mischpfade**: Business-Logic sendet/empfängt **nie** direkt (`rednet`, `modem.transmit`, `os.pullEvent("modem_message")`) außerhalb `core/comms.lua` + `services/comms_service.lua`.
- **COMMAND Lifecycle**: Jeder COMMAND endet deterministisch mit `ACK_DELIVERED` und `ACK_APPLIED` inkl. Ergebnis `{ ok=true }` oder `{ ok=false, error, reason_code }`.
- **Proto/Validation**: Payload-Validation + `proto_ver`-Check; bei Mismatch liefert der Node `ok=false` mit `reason_code=PROTO_MISMATCH`.
- **Timeout/Retry**: Bei ausbleibendem `ACK_APPLIED` markiert der MASTER das Kommando als **failed** und loggt den Grund (`ACK_TIMEOUT`).
- **COMMS_DOWN Semantik**:
  - MASTER setzt Nodes auf `COMMS_DOWN` bei `peer_timeout_s`.
  - Nodes markieren `COMMS_DOWN`, wenn der MASTER nicht erreichbar ist (laufen aber autonom).
- **Diagnostics/Observability**: Master/Nodes zeigen Queue/Inflight/Retry/Dropped/Dedupe-Hits und Peer-Status.

## Manual Test Checklist (Kurz)
1. **Start**: MASTER + RT + ENERGY starten (FUEL/WATER/REPROCESSOR optional).
2. **Comms-Down**: Einen Node stoppen → MASTER zeigt `COMMS_DOWN` + `down_since` + Age; Node läuft lokal weiter.
3. **Comms-Recover**: Node neu starten → MASTER zeigt `OK`, `down_since` reset.
4. **Command Applied**: MASTER sendet Setpoints/Mode → `ACK_APPLIED` sichtbar (ok/failed, reason_code).
5. **Diagnostics**: Master-Resources-Page zeigt `Queue/Inflight/Retry/Dropped/Dedupe` + Peer-Summary.
6. **Node Diagnostics**: Jede Node zeigt MASTER-Link (OK/DOWN + Age) + Queue/Inflight/Retry/Dropped/Dedupe.
7. **Safe Update**: SAFE UPDATE ausführen → keine Rolle/Config-Resets, Rollback bei Fehlern.
8. **Proto-Mismatch**: `proto_ver` Major abweichen lassen → Node antwortet mit `ok=false`, `reason_code=PROTO_MISMATCH`.
9. **Update Recovery Marker**: `/xreactor/.update_in_progress` anlegen → beim Start wird Recovery (Apply/Rollback) ausgeführt und Marker entfernt.

## Rails/Tuning Guide (Kurz)
- **RT Control Rails** werden zentral über `rails` in `master/config.lua` und `nodes/*/config.lua` gesteuert.
- Wichtige Parameter:
  - `deadband_up/down` + `hysteresis_up/down` → verhindert Oszillation/Flip-Flop.
  - `max_step_up/down` + `cooldown_s` → limitiert Sprünge pro Tick.
  - `min/max` → harte Klemmen (Rods 0–98%, Flow 0–1900).
  - `ema_alpha` → optionales Smoothing für noisy Inputs (RPM/Steam).
- Änderungen zuerst im RT-Node testen (beste Hardware-Nähe).

## UI Navigation Guide
- **Master**: Overview / Node Detail / Resources / Diagnostics.
- **Nodes**: Overview / Details / Diagnostics.
- Navigation:
  - Touch auf die Page-Buttons (`<`/`>`) unten.
  - **Keys**: `←`/`→` oder `PageUp`/`PageDown`.
  - Page-Indicator zeigt `X/Y` (aktuelle Seite).

## Modul-Loading & Require-Konzept
- **Zentrale Bootstrap-Lösung**: Jede Entry-Datei (`master/main.lua`, `nodes/*/main.lua`) lädt zuerst `/xreactor/core/bootstrap.lua`.
- **Bootstrap-Aufgabe**: Installiert einen **eigenen Loader** ohne Abhängigkeit von `package.path`. Zusätzlich ergänzt er `package.path` um `/xreactor/?.lua` und `/xreactor/?/init.lua`, damit auch native `require`-Aufrufe immer aus dem Projekt-Root auflösen.
- **Package-Sicherheit**: Falls `package` nicht existiert (einige CC:Tweaked-Umgebungen), erstellt der Bootstrap ein minimales `package`-Objekt, damit `require` zuverlässig funktioniert.
- **Projekt-Root**: Alle Module werden relativ zum festen Root `/xreactor` geladen (z. B. `/xreactor/shared/constants.lua`).
- **Module-Struktur**:
  - `xreactor/shared/*` (z. B. `shared.constants`)
  - `xreactor/shared/health_codes.lua` (Health-Reason-Codes für Master/Nodes)
  - `xreactor/core/*` (z. B. `core.utils`)
  - `xreactor/master/*` (z. B. `master.main`)
  - `xreactor/nodes/*` (z. B. `nodes.rt.main`)
- **Keine globalen Injects**: Alle Module nutzen lokale Requires, z. B. `local utils = require("core.utils")`.
- **Debug-Log**: In den jeweiligen `main.lua`-Dateien kann `BOOTSTRAP_LOG_ENABLED = true` gesetzt werden (Konfig ganz oben). Dann schreibt der Bootstrap eine Datei `/xreactor_logs/loader_<role>.log` (z. B. `loader_master.log`) mit Environment-Infos, Root-Pfad, `package.path`, `shell.dir()` und jedem Modul-Ladeversuch. Optional kann `BOOTSTRAP_LOG_PATH` das Logziel überschreiben. Bei Require-Fehlern werden die tatsächlich geprüften Pfade protokolliert.
- **Warum das wichtig ist**: Ohne Bootstrap nutzt Lua die Standard-`package.path`, die relativ zum aktuellen Programmverzeichnis ist (z. B. `/xreactor/master/?.lua`). Dadurch werden Module wie `shared.constants` fälschlich unter `/xreactor/master/shared/...` gesucht. Der Bootstrap überschreibt `require`, ergänzt `package.path` und installiert einen `package.searcher`, der immer unter `/xreactor` lädt.
- **Empfohlene Nutzung**:
  ```
  local bootstrap = dofile("/xreactor/core/bootstrap.lua")
  bootstrap.setup({ role = "master" })
  local utils = require("core.utils")
  ```

## Installation, Safe Update & Full Reinstall
**Erstinstallation / Vollinstallation**
1. Installer herunterladen und ausführen:
   ```
   lua /installer.lua
   ```
   (Beide Einstiegspunkte sind Bootstrapper: `/installer.lua` und `/xreactor/installer/installer.lua` aktualisieren bei Bedarf `/xreactor/installer/installer_core.lua` und starten anschließend den Core-Installer.)
2. Der Installer läuft standalone; Projekt-Logger wird erst nach erfolgreicher Installation/Update genutzt.
3. Rolle wählen (MASTER/RT/etc.), Modem-Seiten und Node-ID setzen.
4. `startup.lua` wird gesetzt; danach reboot oder manuell starten.

**SAFE UPDATE (inkrementell, ohne Config-Reset)**
- Installer erneut ausführen → Menü **SAFE UPDATE** wählen.
- Lädt nur **geänderte/fehlende** Dateien laut Manifest (dateiweise).
- SAFE UPDATE fragt **keine** Rolle neu ab und überschreibt keine Configs/Node-ID.
- Downloads werden zuerst in ein **Staging-Verzeichnis** (`/xreactor_stage/<timestamp>`) geschrieben, per Checksum verifiziert und erst danach atomar ersetzt.
- Bei Fehler: Rollback aus `/xreactor_backup/<timestamp>/`, keine halbfertigen Updates.
- **Update Marker**: Während des Updates wird `/xreactor/.update_in_progress` geschrieben; beim Start wird Recovery (Apply/Rollback) erzwungen, Marker wird danach entfernt.
- Downloader nutzt **Retries + Backoff**, prüft HTTP-Status/HTML-Fehler und nutzt RAW-Mirrors (`raw.githubusercontent.com`, `raw.github.com`).
- **Size mismatch** gilt nur als Transport-Warnung; die Entscheidung trifft die Checksum. Bei Problemen: Retry.
- Manifest-Cache: `/xreactor/.cache/manifest.lua`. Bei Problemen: **Cached Manifest**, **Retry** oder **Cancel**.
- Updates sind source_ref-gepinnt: Manifest und Dateien kommen aus derselben Base-URL (Commit-SHA bevorzugt, `main` nur Fallback).
- Retry startet den gesamten Download-Teil neu (Manifest wird erneut geladen), um konsistent zu bleiben.
- Installer speichert nur sichere Plain-Data-Snapshots (keine shared refs); Backup/Cache-Indizes sind textbasiert.
- **Protokoll-Änderung**: Wenn das Update eine neue Major-Protokollversion enthält, bricht SAFE UPDATE ab, um inkonsistente Master/Node-Versionen zu vermeiden.
- **Core-Dateien Pflicht**: SAFE UPDATE bricht mit klarer Meldung ab, falls das Manifest essentielle Core-/Shared-Files (z. B. `xreactor/core/utils.lua`, `xreactor/shared/constants.lua`) nicht enthält oder Pfade falsch sind.
- **Datei-Renames/Migrationen**: Wenn Dateien umbenannt/verschoben werden, müssen Migrationsregeln hinterlegt sein – andernfalls wird der Update-Lauf abgebrochen, um halbfertige Zustände zu verhindern.
- **Loader-Garantie**: SAFE UPDATE stellt sicher, dass der Loader (`xreactor/core/bootstrap.lua`) und alle abhängigen Core-Module aus dem Manifest vorhanden sind, bevor ein Start empfohlen wird.

**FULL REINSTALL (alles neu)**
- Installer erneut ausführen → Menü **FULL REINSTALL** wählen.
- Optional: bestehende Config/Rolle/Node-ID behalten (Restore nach Neuinstall).
- Andernfalls: Rolle wird neu abgefragt, Config wird neu geschrieben, `startup.lua` wird gesetzt.

**Offline/Fehlerfälle**
- **HTTP disabled**: HTTP in der CC:Tweaked-Config aktivieren, dann Installer erneut starten.
- **GitHub Timeout**: Installer nutzt Retry; falls weiter fehlschlägt, kann ein Cached Manifest verwendet werden oder der Installer bricht sauber ohne Änderungen ab.

**Installer starten (ohne Neu-Download)**
- Root-Installer (`/installer.lua`) ist ein Bootstrap. Er lädt bei Bedarf den Core-Installer nach `/xreactor/installer/installer_core.lua`.
- Der Installer unter `/xreactor/installer/installer.lua` ist ebenfalls ein Bootstrap und verhält sich identisch.
- SAFE UPDATE läuft immer mit dem lokalen Core-Installer; nur bei Versionssprung wird dieser ersetzt und automatisch neu gestartet.

**Logging & Debugging**
- Bootstrap-Log: `/xreactor_logs/installer_bootstrap.log` (mit Rotation `.1`).
- Installer-Core-Log: `/xreactor_logs/installer.log` (mit Rotation `.1`).
- Node-Logs: `/xreactor/logs/<role>_<node_id>.log` (z. B. `rt_RT-1.log`, `master_MASTER-1.log`).
- Debug-Logging aktivieren: in `xreactor/*/config.lua` `debug_logging = true` setzen.
- Optionaler Override pro Komponente: `DEBUG_LOG_ENABLED` in den jeweiligen `main.lua`-Dateien.

## Konfiguration & Autodetection
- **MASTER**: `xreactor/master/config.lua`
  - `rt_default_mode`: Standardmodus für RT-Nodes (`AUTONOM`, `MASTER`, `SAFE`).
  - `rt_setpoints`: Zielwerte (z. B. `target_rpm`, `enable_reactors`, `enable_turbines`).
- **RT-NODE**: `xreactor/nodes/rt/config.lua`
  - `reactors`, `turbines`: Namen der Peripherals.
  - `wireless_modem`, `wired_modem`: Modem-Seiten.
- **ENERGY/WATER/FUEL/REPROCESSOR**: `xreactor/nodes/<role>/config.lua`
  - `heartbeat_interval`: Sekunden zwischen Status-Heartbeats (Default: **2** bei Nodes, **5** beim MASTER).
  - `wireless_modem`: Wireless-Modem-Seite (Default: `right`).
  - **ENERGY**:
    - Autodetection für **Energy-Storage** über Method-Signaturen (`getEnergy/getMaxEnergy`, `getEnergyStored/getMaxEnergyStored`, `getStoredPower/getMaxStoredPower`).
    - Monitor-Erkennung (lokal oder wired) mit Auswahl per **größtem Monitor** oder **erstem**.
    - Config-Keys:
      - `scan_interval` (Sekunden zwischen Discovery-Scans).
      - `ui_refresh_interval`, `ui_scale` (ENERGY-Node Monitor UI).
      - `monitor.preferred_name`, `monitor.strategy` (`largest`/`first`).
      - `storage_filters.include_names` (Allow-List), `storage_filters.exclude_names` (Deny-List), `storage_filters.prefer_names` (Priorisierung).
      - `matrix`, `matrix_names`, `matrix_aliases` sowie `cubes` bleiben als Legacy-Overrides erhalten.
  - **WATER**: `loop_tanks`, `target_volume` (Tank-Setpoint).
  - **FUEL**: `storage_bus`, `minimum_reserve` (Default: **2000**, kompatibel mit `target`).
  - **REPROCESSOR**: `buffers` (Buffer-Peripherals).
- Autodetection wird genutzt, wo möglich (Monitore/Tank-Namen).
- **Persistenz**:
  - `node_id`: `/xreactor/config/node_id.txt` (immer String)
  - **Device Registry**: `/xreactor/config/registry_<role>_<node_id>.json` (stabile IDs + Aliases, Health-Status)
  - **Source-of-Truth**: Discovery schreibt die Registry; UI/Telemetry lesen **ausschließlich** aus der Registry.
- Manifest: `/xreactor/.manifest`

## Services & Core-Module (Kurz)
- **core/comms.lua**: ACK/Retry/Timeout/Dedupe, Peer-Health.
- **core/health.lua**: Standardisiertes Health-Schema (OK/DEGRADED/DOWN + Reasons).
- **core/registry.lua**: Persistente Device Registry (stable IDs, alias mapping, health).
- **services/**: Lifecycle Services (comms, discovery, telemetry, ui, control) mit `service_manager`.
- **adapters/**: Einheitliche Adapter für Monitor, Energy Storage, Induction Matrix, Reactor, Turbine.
- **shared/health_codes.lua**: Einheitliche Reason-Codes für Health-Status.
- **shared/telemetry_schema.lua**: Dokumentiertes Telemetry-Schema (Schema-Version + Rollenfelder).
- **shared/build_info.lua**: Build-Metadaten (Commit/Version aus `installer/release.lua`).

## ENERGY Node Monitor UI
- Der ENERGY-Node nutzt den **direkt angeschlossenen Monitor** für eine lokale Anzeige.
- Inhalte:
  - Induction Matrices: **pro Matrix** Stored/Capacity/% + IN/OUT (falls API verfügbar), inkl. Füllstand-Balken.
  - **GESAMT**-Block: Summe Stored/Capacity/% + optional Summe IN/OUT.
  - **Diagnostics**-Seite: Peripherals gefunden/gebunden, letzter Scan, letzter Fehler.
- Storages-Seite: Liste der erkannten Storages (optional zweite Seite).
- Paging: Touch auf `<`/`>` in der Fußzeile oder Pfeiltasten links/rechts.
- Werte, die die API nicht liefert, werden als **`n/a`** angezeigt.

## Recovery & Rollback
- Backups liegen unter `/xreactor_backup/<timestamp>/`.
- SAFE UPDATE führt bei Fehlern automatisch Rollback durch und lässt den alten Stand bestehen.
- Manuelles Rollback: Dateien aus dem Backup-Verzeichnis zurück nach `/xreactor/` kopieren (z. B. bei Stromausfall während Updates).

## Debug-Logging
- **Standardmäßig AUS**.
- Aktivieren über:
  - Config-Datei der Rolle (`debug_logging = true`), oder
  - Settings API: `settings.set("xreactor.debug_logging", true)` + `settings.save()`.
- **Config-Fallback-Logs**: Falls eine Config fehlt/invalid ist, schreibt der Node automatisch eine Warnung ins Log und nutzt Defaults, um Start-Crashes zu vermeiden.
- Logfiles:
- Bootstrap: `/xreactor_logs/installer_bootstrap.log` (Rotation `.1`)
- Installer-Core: `/xreactor_logs/installer.log` (Rotation `.1`)
  - Nodes: `/xreactor/logs/<role>_<node_id>.log` (z. B. `rt_RT-1.log`)
- ENERGY-Node schreibt bei aktiviertem Debug einmal pro Discovery-Scan einen **Discovery Snapshot** (Peripherie-Liste + Types + Methoden der Kandidaten).
- Matrix-Debug: Wenn Component-Counts fehlen, loggt der ENERGY-Node die verfügbaren Matrix-Methoden (kein Terminal-Spam).
- Format: `[Zeit] PREFIX | LEVEL | Nachricht`

## Betrieb (Modi)
- **AUTONOM**: RT-Node regelt lokal (bestehende Standalone-Logik bleibt aktiv).
- **MASTER**: MASTER gibt Setpoints vor (z. B. Ziel-RPM); lokale Schutzlogik bleibt immer Vorrang.
- **SAFE**: RT-Node fährt in sicheren Zustand (Rods hoch, Turbinen aus).

## Troubleshooting
- **Timeout/Offline**: Prüfe Heartbeat-Intervalle und Wireless-Reichweite.
- **Falsche Modem-Seite**: `wireless_modem`/`wired_modem` in `config.lua` prüfen.
- **Module not found**: Prüfe, ob `/xreactor/shared/constants.lua` vorhanden ist und ob der Bootstrap vor allen `require`-Aufrufen läuft (Entry-File lädt `/xreactor/core/bootstrap.lua` zuerst). Bei aktivem `BOOTSTRAP_LOG_ENABLED` kontrolliere `/xreactor_logs/loader_<role>.log` für `package.path`, `shell.dir()` und die tatsächlich versuchten Pfade.
- **Proto-Mismatch**: `proto_ver` prüfen; alte Nodes ignorieren neue Nachrichten.
- **Proto-Mismatch Verhalten**: inkompatible Nachrichten werden ignoriert (kein Crash/Flapping), Update empfohlen.
- **COMMS_DOWN**: Node ist > Timeout nicht gesehen → Master markiert DOWN.
- **Node stale / ACK timeout**: Prüfe `comms.ack_timeout_s`, Reichweite/Interferenz und ob Nodes ACK_APPLIED senden.
- **DISCOVERY_FAILED**: Discovery-Scan konnte nicht laufen; prüfe Peripherals + Modem.
- **Reason-Codes**: Zentral definiert in `xreactor/shared/health_codes.lua` (Master/Nodes nutzen identische Codes).
- **Device not bound**: Diagnostics-Page der Node prüfen (Registry zeigt Found/Bound/Missing + letzte Fehler).
- **Registry corrupt**: Datei `registry_<role>_<node_id>.json.broken_<timestamp>` wird erzeugt; Node läuft weiter im DEGRADED-Modus.
- **Update fehlgeschlagen**: Rollback wird automatisch durchgeführt, Backup unter `/xreactor_backup/<timestamp>/`.
- **Manifest-Download fehlgeschlagen**: Retry nutzen oder Cache verwenden (falls vorhanden).
- **Retry-Menü**: Bei Download-Fehlern gibt es immer ein Retry/Cancel-Menü; Retry versucht den Download erneut mit kurzer Wartezeit.
- **Installer-Details**: Der Fehlerdialog zeigt die tatsächlich verwendeten RAW-URLs (Tried) und den letzten Fehler (z. B. Timeout, HTTP-Status, HTML-Response).
- **HTTP API**: Wenn der Installer meldet, dass HTTP nicht verfügbar ist, aktiviere es in der CC:Tweaked-Konfiguration.
- **HTML-Response**: Weist auf falsche URL (z. B. GitHub-Blob) oder Proxy hin – der Installer erwartet RAW-Links.
- **404 bei Dateien**: Wenn ein gepinnter Commit nicht mehr passt, fällt der Installer automatisch auf `main` zurück, statt weiter 404s zu produzieren.
- **HTML statt Lua**: Installer bricht ab (meist falscher Link oder GitHub-Rate-Limit).
- **Installer core download failed**: Prüfe HTTP-API/Timeouts und ob `xreactor/installer/release.lua` (Hash/Size) zum tatsächlichen `installer_core.lua` passt.
- **node_id Migration**: SAFE UPDATE versucht alte Speicherorte zu übernehmen (z. B. alte Config/Dateien) und normalisiert auf String.
- **SAFE UPDATE Abbruch**: Bei Download-Problemen kann der Nutzer abbrechen; das System bleibt unverändert.
- **Manueller Restore**: Inhalte aus dem Backup zurückkopieren, danach reboot.
- **Peripherals fehlen**: Namen in `config.lua` prüfen, Wired-Modem korrekt angeschlossen?
- **ENERGY ok aber keine Storages/Monitor gebunden**:
  - Discovery-Log prüfen: `/xreactor/logs/energy_<node_id>.log`
  - `storage_filters.include_names`/`exclude_names` checken.
  - Wired-Modem korrekt verbunden? `peripheral.getNames()` sollte Remote-Peripherals listen.
  - Peripherals müssen Energy-Methoden anbieten (siehe Autodetection-Methoden).
- **ENERGY Monitor zeigt “n/a”**:
  - Die API liefert diese Werte nicht (z. B. Matrix-Komponenten-Counts).
  - Debug-Log zeigt die verfügbaren Methoden am Matrix-Peripheral.
- **Node bleibt in SAFE**: Temperatur/Water-Limits prüfen, ggf. Ursache beseitigen und Modus wechseln.

## Telemetry-Schema (Kurz)
- Jeder STATUS-Payload enthält `meta` mit `proto_ver`, `role`, `node_id`, `build` und `schema_version`.
- Gemeinsame Felder: `health`, `bindings`, `bindings_summary`, `registry`.
- Rollen-Felder:
  - **ENERGY**: `total`, `matrices[]`, `stores[]`.
  - **RT**: `turbines[]`, `reactors[]`, `control_mode`, `ramp_state`.
  - **FUEL**: `sources[]`, `reserve`, `minimum_reserve`.
  - **WATER**: `total_water`, `buffers[]`.
  - **REPROCESSOR**: `buffers[]`, `standby`.

## Manual Test Checklist (Step 2)
1. **MASTER starten** → Overview zeigt Nodes + Health/Reasons/Bindings.
2. **RT starten** → Turbines/Reaktoren sichtbar, Health OK/DEGRADED korrekt.
3. **ENERGY starten** → Matrices + Total sichtbar, Diagnostics zeigt Registry.

## Manual Test Checklist (Step 3 – Comms)
1. **MASTER starten**, danach **Node starten** → Node erscheint mit `last_seen`/Age.
2. **Node stoppen** → MASTER zeigt `DOWN/COMMS_DOWN` nach Timeout.
3. **COMMAND senden** (z. B. RT target RPM) → `ACK_APPLIED` im Master-Log/Diagnostics sichtbar.
4. **Diagnostics Pages** (ENERGY/RT/FUEL/WATER/REPROC) → Registry snapshot + last errors sichtbar.
5. **Safe Update** ausführen → Rolle/Config bleiben erhalten, neue Dateien sind vorhanden.

## Wie teste ich das System? (6 Szenarien)
1. **RT-Node startet ohne MASTER** → läuft stabil in **AUTONOM**.
2. **MASTER startet später** → RT-Node registriert sich und sendet Status.
3. **MASTER setzt Modus auf MASTER** → Setpoints greifen (z. B. `target_rpm`).
4. **MASTER fällt aus** → RT-Node wechselt automatisch zurück auf **AUTONOM**.
5. **Mehrere RT-Nodes** → MASTER zeigt/verwaltet alle Nodes parallel.
6. **Startup-Sequencer** → Module/Turbinen werden nacheinander hochgefahren.

## Lizenz
MIT-Lizenz – siehe `LICENSE`.
