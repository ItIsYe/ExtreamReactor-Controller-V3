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

## Modul-Loading & Require-Konzept
- **Zentrale Bootstrap-Lösung**: Jede Entry-Datei (`master/main.lua`, `nodes/*/main.lua`) lädt zuerst `/xreactor/core/bootstrap.lua`.
- **Bootstrap-Aufgabe**: Installiert einen **eigenen Loader** ohne Abhängigkeit von `package.path`. Zusätzlich ergänzt er `package.path` um `/xreactor/?.lua` und `/xreactor/?/init.lua`, damit auch native `require`-Aufrufe immer aus dem Projekt-Root auflösen.
- **Projekt-Root**: Alle Module werden relativ zum festen Root `/xreactor` geladen (z. B. `/xreactor/shared/constants.lua`).
- **Module-Struktur**:
  - `xreactor/shared/*` (z. B. `shared.constants`)
  - `xreactor/core/*` (z. B. `core.utils`)
  - `xreactor/master/*` (z. B. `master.main`)
  - `xreactor/nodes/*` (z. B. `nodes.rt.main`)
- **Keine globalen Injects**: Alle Module nutzen lokale Requires, z. B. `local utils = require("core.utils")`.
- **Debug-Log**: In den jeweiligen `main.lua`-Dateien kann `BOOTSTRAP_LOG_ENABLED = true` gesetzt werden (Konfig ganz oben). Dann schreibt der Bootstrap eine Datei `/xreactor/logs/loader_<role>.log` (z. B. `loader_master.log`) mit Environment-Infos, Root-Pfad, `package.path` und jedem Modul-Ladeversuch. Optional kann `BOOTSTRAP_LOG_PATH` das Logziel überschreiben. Bei Require-Fehlern werden die tatsächlich geprüften Pfade protokolliert.
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
- Downloader nutzt **Retries + Backoff**, prüft HTTP-Status/HTML-Fehler und nutzt RAW-Mirrors (`raw.githubusercontent.com`, `raw.github.com`).
- **Size mismatch** gilt nur als Transport-Warnung; die Entscheidung trifft die Checksum. Bei Problemen: Retry.
- Manifest-Cache: `/xreactor/.cache/manifest.lua`. Bei Problemen: **Cached Manifest**, **Retry** oder **Cancel**.
- Updates sind source_ref-gepinnt: Manifest und Dateien kommen aus derselben Base-URL (Commit-SHA bevorzugt, `main` nur Fallback).
- Retry startet den gesamten Download-Teil neu (Manifest wird erneut geladen), um konsistent zu bleiben.
- Installer speichert nur sichere Plain-Data-Snapshots (keine shared refs); Backup/Cache-Indizes sind textbasiert.
- **Protokoll-Änderung**: Wenn das Update eine neue Major-Protokollversion enthält, bricht SAFE UPDATE ab, um inkonsistente Master/Node-Versionen zu vermeiden.
- **Core-Dateien Pflicht**: SAFE UPDATE bricht mit klarer Meldung ab, falls das Manifest essentielle Core-Files (z. B. `xreactor/core/utils.lua`) nicht enthält oder Pfade falsch sind.
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
- Bootstrap-Log: `/xreactor/logs/installer_bootstrap.log` (mit Rotation `.1`).
- Installer-Core-Log: `/xreactor/logs/installer.log` (mit Rotation `.1`).
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
- Autodetection wird genutzt, wo möglich (Monitore/Tank-Namen).
- **Persistenz**:
  - `node_id`: `/xreactor/config/node_id.txt` (immer String)
- Manifest: `/xreactor/.manifest`

## Recovery & Rollback
- Backups liegen unter `/xreactor_backup/<timestamp>/`.
- SAFE UPDATE führt bei Fehlern automatisch Rollback durch und lässt den alten Stand bestehen.
- Manuelles Rollback: Dateien aus dem Backup-Verzeichnis zurück nach `/xreactor/` kopieren (z. B. bei Stromausfall während Updates).

## Debug-Logging
- **Standardmäßig AUS**.
- Aktivieren über:
  - Config-Datei der Rolle (`debug_logging = true`), oder
  - Settings API: `settings.set("xreactor.debug_logging", true)` + `settings.save()`.
- Logfiles:
  - Bootstrap: `/xreactor/logs/installer_bootstrap.log` (Rotation `.1`)
  - Installer-Core: `/xreactor/logs/installer.log` (Rotation `.1`)
  - Nodes: `/xreactor/logs/<role>_<node_id>.log` (z. B. `rt_RT-1.log`)
- Format: `[Zeit] PREFIX | LEVEL | Nachricht`

## Betrieb (Modi)
- **AUTONOM**: RT-Node regelt lokal (bestehende Standalone-Logik bleibt aktiv).
- **MASTER**: MASTER gibt Setpoints vor (z. B. Ziel-RPM); lokale Schutzlogik bleibt immer Vorrang.
- **SAFE**: RT-Node fährt in sicheren Zustand (Rods hoch, Turbinen aus).

## Troubleshooting
- **Timeout/Offline**: Prüfe Heartbeat-Intervalle und Wireless-Reichweite.
- **Falsche Modem-Seite**: `wireless_modem`/`wired_modem` in `config.lua` prüfen.
- **Proto-Mismatch**: `proto_ver` prüfen; alte Nodes ignorieren neue Nachrichten.
- **Proto-Mismatch Verhalten**: inkompatible Nachrichten werden ignoriert (kein Crash/Flapping), Update empfohlen.
- **Update fehlgeschlagen**: Rollback wird automatisch durchgeführt, Backup unter `/xreactor_backup/<timestamp>/`.
- **Manifest-Download fehlgeschlagen**: Retry nutzen oder Cache verwenden (falls vorhanden).
- **Retry-Menü**: Bei Download-Fehlern gibt es immer ein Retry/Cancel-Menü; Retry versucht den Download erneut mit kurzer Wartezeit.
- **Installer-Details**: Der Fehlerdialog zeigt die tatsächlich verwendeten RAW-URLs (Tried) und den letzten Fehler (z. B. Timeout, HTTP-Status, HTML-Response).
- **HTTP API**: Wenn der Installer meldet, dass HTTP nicht verfügbar ist, aktiviere es in der CC:Tweaked-Konfiguration.
- **HTML-Response**: Weist auf falsche URL (z. B. GitHub-Blob) oder Proxy hin – der Installer erwartet RAW-Links.
- **404 bei Dateien**: Wenn ein gepinnter Commit nicht mehr passt, fällt der Installer automatisch auf `main` zurück, statt weiter 404s zu produzieren.
- **HTML statt Lua**: Installer bricht ab (meist falscher Link oder GitHub-Rate-Limit).
- **node_id Migration**: SAFE UPDATE versucht alte Speicherorte zu übernehmen (z. B. alte Config/Dateien) und normalisiert auf String.
- **SAFE UPDATE Abbruch**: Bei Download-Problemen kann der Nutzer abbrechen; das System bleibt unverändert.
- **Manueller Restore**: Inhalte aus dem Backup zurückkopieren, danach reboot.
- **Peripherals fehlen**: Namen in `config.lua` prüfen, Wired-Modem korrekt angeschlossen?
- **Node bleibt in SAFE**: Temperatur/Water-Limits prüfen, ggf. Ursache beseitigen und Modus wechseln.

## Wie teste ich das System? (6 Szenarien)
1. **RT-Node startet ohne MASTER** → läuft stabil in **AUTONOM**.
2. **MASTER startet später** → RT-Node registriert sich und sendet Status.
3. **MASTER setzt Modus auf MASTER** → Setpoints greifen (z. B. `target_rpm`).
4. **MASTER fällt aus** → RT-Node wechselt automatisch zurück auf **AUTONOM**.
5. **Mehrere RT-Nodes** → MASTER zeigt/verwaltet alle Nodes parallel.
6. **Startup-Sequencer** → Module/Turbinen werden nacheinander hochgefahren.

## Lizenz
MIT-Lizenz – siehe `LICENSE`.
