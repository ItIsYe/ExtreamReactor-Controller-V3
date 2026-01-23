# Migration Guide (Beta → Final)

## Ziel
Dieser Guide beschreibt die Migration von der Beta-Branch auf die finalisierte Architektur mit Comms/Services/Registry/Health sowie dem Safe-Update-Staging.

## Empfohlener Pfad
1. **SAFE UPDATE** mit dem Installer starten (`lua /installer.lua` → SAFE UPDATE).
2. Warten, bis Download + Verifikation abgeschlossen sind (Staging wird vollständig geprüft, bevor Live-Dateien getauscht werden).
3. Nach Abschluss einmal neu starten (`reboot`), damit Services sauber init/stop durchlaufen.

## Wann FULL REINSTALL nötig ist
- **Protokoll-Major-Änderung** (proto_ver major).
- Installer meldet, dass eine Migration nicht möglich ist (z. B. fehlende Migration Targets).
- Beschädigte lokale Dateien/Config, die nicht mehr geladen werden können.

## Was SAFE UPDATE **nicht** ändert
- Rolle (`role`).
- Node-ID (`/xreactor/config/node_id.txt`).
- Lokale Configs (`xreactor/*/config.lua`).

## Registry-Änderung
- Neue Registry-Datei pro Rolle: `/xreactor/config/registry_<role>_<node_id>.json`.
- Bestehende Registry-Dateien werden beim nächsten Discovery-Lauf neu aufgebaut.

## Nach der Migration prüfen
- Logs: `/xreactor/logs/<role>_<node_id>.log`.
- Master UI: Node-Status + Degraded-Reasons.
- SAFE UPDATE: `/xreactor/.manifest` und `/xreactor/.cache/manifest.lua` aktualisiert.
