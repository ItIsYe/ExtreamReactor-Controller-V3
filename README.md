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

## Installation, Safe Update & Full Reinstall
**Erstinstallation / Vollinstallation**
1. Ordner `xreactor` auf die jeweiligen Computer kopieren.
2. Root-Installer ausführen (`/installer.lua` bleibt stabil und wird nicht im SAFE UPDATE ersetzt):
   ```
   lua /installer.lua
   ```
3. Rolle wählen (MASTER/RT/etc.), Modem-Seiten und Node-ID setzen.
4. `startup.lua` wird gesetzt; danach reboot oder manuell starten.

**SAFE UPDATE (inkrementell, ohne Config-Reset)**
- Installer erneut ausführen → Menü **SAFE UPDATE** wählen.
- Lädt nur geänderte Dateien laut Manifest, macht ein Backup, schützt lokale Config/Node-ID.
- Bei Fehler: automatischer Rollback aus dem Backup.
- Der Installer selbst wird nur aktualisiert, wenn `installer_min_version` dies verlangt.

**FULL REINSTALL (alles neu)**
- Installer erneut ausführen → Menü **FULL REINSTALL** wählen.
- Rolle wird neu abgefragt, Config wird neu geschrieben, `startup.lua` wird gesetzt.

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
- **node_id Migration**: SAFE UPDATE versucht alte Speicherorte zu übernehmen (z. B. alte Config/Dateien).
- **SAFE UPDATE Abbruch**: Wenn keine sichere node_id-Recovery möglich ist, wird SAFE UPDATE abgebrochen, ohne Änderungen zu übernehmen.
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
