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
- **Wichtig**: Der MASTER greift **nie** direkt auf Peripherals zu – nur die Nodes tun das.

## Installation & Start
1. Ordner `xreactor` auf die jeweiligen Computer kopieren.
2. Installer ausführen:
   ```
   cd /xreactor
   lua installer/installer.lua
   ```
3. Rolle wählen (MASTER/RT/etc.), Modem-Seiten und Node-ID setzen.
4. Neustart oder Start via `startup.lua` (Installer legt diese an).

## Konfiguration & Autodetection
- **MASTER**: `xreactor/master/config.lua`
  - `rt_default_mode`: Standardmodus für RT-Nodes (`AUTONOM`, `MASTER`, `SAFE`).
  - `rt_setpoints`: Zielwerte (z. B. `target_rpm`, `enable_reactors`, `enable_turbines`).
- **RT-NODE**: `xreactor/nodes/rt/config.lua`
  - `reactors`, `turbines`: Namen der Peripherals.
  - `wireless_modem`, `wired_modem`: Modem-Seiten.
- Autodetection wird genutzt, wo möglich (Monitore/Tank-Namen).

## Betrieb (Modi)
- **AUTONOM**: RT-Node regelt lokal (bestehende Standalone-Logik bleibt aktiv).
- **MASTER**: MASTER gibt Setpoints vor (z. B. Ziel-RPM); lokale Schutzlogik bleibt immer Vorrang.
- **SAFE**: RT-Node fährt in sicheren Zustand (Rods hoch, Turbinen aus).

## Troubleshooting
- **Keine Verbindung**: Wireless-Modem prüfen, Kanäle 6500/6501 frei.
- **Peripherals fehlen**: Namen in `config.lua` prüfen, Wired-Modem korrekt angeschlossen?
- **Node bleibt in SAFE**: Temperatur/Water-Limits prüfen, ggf. Ursache beseitigen und Modus wechseln.
- **Sequencer wartet**: RT-Node muss ACK und STABLE melden; Modul-Status prüfen.

## Wie teste ich das System? (6 Szenarien)
1. **RT-Node startet ohne MASTER** → läuft stabil in **AUTONOM**.
2. **MASTER startet später** → RT-Node registriert sich und sendet Status.
3. **MASTER setzt Modus auf MASTER** → Setpoints greifen (z. B. `target_rpm`).
4. **MASTER fällt aus** → RT-Node wechselt automatisch zurück auf **AUTONOM**.
5. **Mehrere RT-Nodes** → MASTER zeigt/verwaltet alle Nodes parallel.
6. **Startup-Sequencer** → Module/Turbinen werden nacheinander hochgefahren.

## Lizenz
MIT-Lizenz – siehe `LICENSE`.
