# Migration Guide (Beta → Final)

## Ziel
Dieser Guide beschreibt die Migration von der Beta-Branch auf die finalisierte Architektur mit Comms/Services/Registry/Health sowie dem Safe-Update-Staging.

## Empfohlener Pfad
1. **SAFE UPDATE** mit dem Installer starten (`lua /installer.lua` → SAFE UPDATE).
2. Warten, bis Download + Verifikation abgeschlossen sind (Staging wird vollständig geprüft, bevor Live-Dateien getauscht werden).
3. Nach Abschluss einmal neu starten (`reboot`), damit Services sauber init/stop durchlaufen.

## Full-Reinstall
Ein Full-Reinstall ist **nicht nötig**; SAFE UPDATE, Delta-Update und Recovery halten den Stand konsistent, ohne Config-Reset.

## Was SAFE UPDATE **nicht** ändert
- Rolle (`role`).
- Node-ID (`/disk/xreactor/config/node_id.txt`).
- Lokale Configs (`/disk/xreactor/*/config.lua`).

## Registry-Änderung
- Neue Registry-Datei pro Rolle: `/disk/xreactor/config/registry_<role>_<node_id>.json`.
- Bestehende Registry-Dateien werden beim nächsten Discovery-Lauf neu aufgebaut.

## Nach der Migration prüfen
- Logs: `/disk/xreactor_logs/<role>_<node_id>.log`.
- Master UI: Node-Status + Degraded-Reasons.
- SAFE UPDATE: `/disk/xreactor/.manifest` und `/disk/xreactor/.cache/manifest.lua` aktualisiert.
