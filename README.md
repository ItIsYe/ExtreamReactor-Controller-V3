# XReactor Controller V3

CC:Tweaked SCADA-Steuerung für Extreme Reactors 2 auf ATM10 (Minecraft 1.21.1).

> **Status:** siehe [`docs/SESSION_HANDOFF.md`](docs/SESSION_HANDOFF.md) für den aktuellen Projektstand

## Schnellstart

### Installer laden (auf einem CC:Tweaked Computer)
```
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
```
Dann Computer neu starten — der Installer erkennt die Rolle automatisch und installiert alle nötigen Dateien.

## System-Überblick

| Rolle | Beschreibung |
|---|---|
| MASTER | Zentrale Steuerung, Monitor-UI, RT-Sync |
| RT | Reaktor- und Turbinen-Steuerung (Echtzeit) |
| ENERGY | Induction Matrix Monitoring |
| FUEL | Brennstoff-Verwaltung und Logistics |
| VALVE | Ventil-Steuerung (Redstone) |
| WATER | Wasserkühlung |
| LOG | Zentraler Log-Collector |

## Branches
- `beta` — aktueller Entwicklungszweig
- `main` — stabile Releases

## Dokumentation
- [`docs/SESSION_HANDOFF.md`](docs/SESSION_HANDOFF.md) — aktueller Projektstatus
- [`docs/CI_MAINTENANCE.md`](docs/CI_MAINTENANCE.md) — CI-Wartung und bekannte Bugs
- [`docs/README.md`](docs/README.md) — vollständiger Dokumentationsindex

## Wichtige Regeln
- Dateien **ausschließlich über den Installer** installieren — nie manuell per curl/Server-Konsole
- Manifest und release.lua werden automatisch bei jedem Commit aktualisiert
- Vor dem Mergen von Agent-generierten PRs: einzeln auf einem Test-Computer verifizieren
