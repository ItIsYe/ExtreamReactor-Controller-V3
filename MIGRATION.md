# Migration Guide (aktueller Stand)

## Ziel
Diese Migration beschreibt den **aktuellen** Wechsel auf den neuesten Repo-Stand mit dem lokalen Installer-Flow.

## Empfohlener Ablauf
1. Installer lokal starten: `installer`.
2. Im Menü `Update` wählen.
3. Der Installer lädt das Manifest, ermittelt die installierte Rolle aus `/xreactor/config/role.lua` und berechnet den Storage-Preflight.
4. Dateien werden nach `/xreactor_stage` geladen und verifiziert.
5. Bestehende Config aus `/xreactor/config` wird ins Stage übernommen.
6. Aktivierung/Commit:
   - aktives `/xreactor` -> `/xreactor_backup_prev`
   - `/xreactor_stage` -> `/xreactor`
   - Backup wird nach erfolgreichem Commit gelöscht.
7. Optional `reboot`, damit alle Dienste sauber neu starten.

> Hinweis: Der Update-Flow ist lokal-only (lokale Stage/Backup/Activate-Pfade). Optionale Disk-Pfade betreffen Runtime-Logging, nicht den Installer-Commit.

## Was beim Update erhalten bleibt
- Rolle (`/xreactor/config/role.lua`, wird nach Update erneut sichergestellt).
- Bestehende Runtime-Config in `/xreactor/config/*` (wird vor Aktivierung ins Stage kopiert).
- `/startup`, sofern ein nicht-XReactor-Startup absichtlich geschützt ist (wird dann nicht überschrieben).

## Pfade (Update vs. Runtime)

### Update-relevant (Installer)
- Install root: `/xreactor`
- Stage root: `/xreactor_stage`
- Backup root: `/xreactor_backup_prev`
- Installer-Log: `/xreactor_logs/installer.log`

### Runtime-/Logging-Pfade
- Runtime-Logs liegen unter `/xreactor_logs` (bei vorhandener Disk können Runtime-Logs auf Disk-basierte Pfade umgeleitet sein; der Update-Flow selbst bleibt lokal).
- Rollen-/Knoten-bezogene Runtime-Dateien bleiben unter `/xreactor/config/*`.

## Safety-/RT-Migrationshinweis
- ENERGY sendet Heartbeats jetzt robuster bei hoher Last:
  - Matrix-Energiemetriken (`stored/capacity/input/output`) werden standardmäßig nur noch alle `2.0s` gepollt (`matrix_metric_poll_interval`), statt bei jedem UI-/Telemetry-Statusaufbau.
  - Neue Schutzschranke `matrix_metric_call_budget` (Default `4`) begrenzt teure Matrix-Einzelabfragen pro Payload-Build; fällige Reads werden fair über mehrere Ticks verteilt statt in einem Block ausgeführt.
  - UI und TELEMETRY teilen dadurch denselben Matrix-Metrik-Cache pro Matrix; doppelte teure Reads im Sekundentakt werden vermieden.
  - Bei aktivem Budget-Limit bleibt Diagnose sichtbar (`Matrix metric polling throttled: due=... budget=... deferred=...`) und die bisherigen Slow-Call-Details (`Status payload slow matrix calls: ...`) bleiben erhalten.
  - Bei langsamen Statuspayloads werden die konkret langsamsten Matrix-Calls mitgeloggt (`Status payload slow matrix calls: <matrix>.<metric>=...ms`) für schnellere Engpass-Lokalisierung.
  - Matrix-Komponenten-Zählwerte (`cells/providers/ports`) werden standardmäßig nur noch alle `30s` gepollt (`matrix_component_poll_interval`), statt bei jedem Statusaufbau.
  - Dadurch werden lange blockierende Matrix-Komponenten-Calls deutlich reduziert und der 2s-Heartbeat-Rhythmus stabilisiert.
  - Für Ursachenanalyse loggt der Service-Manager jetzt langsame Service-Ticks (`Service tick slow`) und langsame Gesamt-Ticks (`Service manager tick slow`).
  - Service-Namen im Slow-Tick-Log sind jetzt immer eindeutig (`COMMS`, `DISCOVERY`, `TELEMETRY`, `UI` bzw. `service#N` als Fallback); der anonyme `?`-Eintrag entfällt.
  - ENERGY cached den Statusaufbau kurzzeitig (`~1s`) zwischen TELEMETRY und UI, inklusive Slow-Stage-Logs (`Status payload slow: storage=... matrix=...`), damit doppelte teure Peripheral-Reads im selben Tick ausbleiben.
  - Heartbeat/Presence ist jetzt hart vom schweren Servicepfad getrennt:
    - minimale Presence-Payload (`ts`, `node_id`, `role`) ohne Matrix/UI-Daten,
    - eigener Heartbeat-Pump (`run_heartbeat_pump`) auf Timerpfad und zusätzlich vor/nach jedem Service im Service-Manager,
    - unmittelbares Ausleiten über `comms:tick(ts)` direkt nach `comms:send_heartbeat(...)`, damit Heartbeats nicht auf den nächsten schweren Gesamttick warten.
- MASTER-Monitor-Scale wird jetzt pro Monitor-Name zwischengespeichert (statt pro temporärem Wrap-Objekt), damit periodische Monitor-Scans keine identischen `setTextScale`-Wiederholungen und keinen Log-Spam mehr auslösen.
- Wenn ein Monitor wirklich verschwindet und später neu erkannt/rebound wird, wird der Cache für diesen Namen invalidiert und die Scale beim Rebind wieder korrekt gesetzt.
- `SAFETY_COOLANT_LOW` wird nicht mehr sofort ausgelöst: zuerst Pending (`COOLANT_LOW_PENDING`), Bestätigung erst nach ~4s persistenter Unterschreitung; Recovery im Pending-Fenster bricht den Pending-Fall ab.
- RT-Regelung nutzt aktive Target-Trim- und Readback-Diagnosezustände (u. a. `ACTIVE_TRIM_WITH_READBACK_LAG`, `TRIM_PENDING_CONFIRMATION`, `READBACK_SETTLING_HOLD`) sowie Overspeed-Bremszustände (`OVERSPEED_BRAKE`, inkl. Flow `0`).
- Neuer offizieller RT-Konfig-Pfad für den automatischen Rod-Regler:
  - `autonom.regulator_min_rods` (Default `80`, entspricht max. 20% automatischer Reaktorleistung; 100% rods = 0% Leistung, 0% rods = 100% Leistung)
  - `autonom.regulator_max_rods` (Default `98`)
  - Bereich `0..100`, bei `min > max` werden die Werte deterministisch getauscht.
  - Legacy-Felder `autonom.min_rods` / `autonom.max_rods` werden bei fehlenden neuen Feldern weiterhin als Fallback gelesen.
- Zusätzliches RT-Sekundärsignal für aktive Kühlung:
  - `rails.reactor_steam_guard` nutzt internen Reaktor-Steam/Hot-Fluid-Füllstand als Guard (nicht als Primär-Führungsgröße).
  - Hoher Füllstand blockiert weiteres Öffnen; kritischer Füllstand kann kontrolliertes Schließen erzwingen.
  - Guard arbeitet geglättet (`ema_alpha`) und mit Hysterese (`high*`/`critical*` + `*_release`), um Oszillation zu vermeiden.
