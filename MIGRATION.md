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
- `SAFETY_COOLANT_LOW` wird nicht mehr sofort ausgelöst: zuerst Pending (`COOLANT_LOW_PENDING`), Bestätigung erst nach ~4s persistenter Unterschreitung; Recovery im Pending-Fenster bricht den Pending-Fall ab.
- RT-Regelung nutzt aktive Target-Trim- und Readback-Diagnosezustände (u. a. `ACTIVE_TRIM_WITH_READBACK_LAG`, `TRIM_PENDING_CONFIRMATION`, `READBACK_SETTLING_HOLD`) sowie Overspeed-Bremszustände (`OVERSPEED_BRAKE`, inkl. Flow `0`).
- Neuer offizieller RT-Konfig-Pfad für den automatischen Rod-Regler:
  - `autonom.regulator_min_rods` (Default `80`, entspricht max. 20% automatischer Reaktorleistung; 100% rods = 0% Leistung, 0% rods = 100% Leistung)
  - `autonom.regulator_max_rods` (Default `98`)
  - Bereich `0..100`, bei `min > max` werden die Werte deterministisch getauscht.
  - Legacy-Felder `autonom.min_rods` / `autonom.max_rods` werden bei fehlenden neuen Feldern weiterhin als Fallback gelesen.
