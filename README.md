# XReactor Controller V3

A modular, SCADA-inspired control stack for **Minecraft 1.21** with **ComputerCraft**, **Extreme Reactors**, **Mekanism**, and optional **Applied Energistics 2** storage. The project provides a MASTER station with multi-monitor GUI and a fleet of autonomous nodes that manage reactors, turbines, water loops, fuel reserves, reprocessing, and energy telemetry.

## Unterstützte Mods & Versionen
- Minecraft 1.21
- ComputerCraft (CC:Tweaked recommended)
- Extreme Reactors
- Mekanism (Energy Cubes & Induction Matrix)
- Applied Energistics 2 (Fuel storage optional)

## Architektur
```
xreactor
├─ MASTER (Wireless control) ──┐
│                              │
│   ┌────────────┐             │
│   │ Monitors   │ (wired)     │
│   └────────────┘             │
│          ▲                   │
│          │ status/commands   │
└──► Wireless Modem ◄──────────┘
           │
           ▼
   ┌───────────────┬──────────────┬──────────────┬───────────────┬────────────────┐
   │ RT-NODE       │ WATER-NODE   │ ENERGY-NODE  │ FUEL-NODE     │ REPROCESSOR    │
   │ (reactor/turb)│ (closed loop)│ (telemetry)  │ (reserve mgr) │ (waste ctrl)   │
   └───────────────┴──────────────┴──────────────┴───────────────┴────────────────┘
           │ (wired)
           ▼
   Connected peripherals (machines, buffers, valves)
```

## Rollenbeschreibung
- **MASTER**: Aggregiert Status, trifft Entscheidungen, orchestriert Startup-Sequenzen und rendert Multi-Monitor-GUIs (Overview, RT Dashboard, Energy, Fuel/Water, Alarm Wall).
- **RT-NODE**: Steuert 1..N Reaktoren und 0..M Turbinen, folgt Master-Zielen, schützt lokal (SCRAM, Steam-Drossel, Leistungsbegrenzung) und geht bei Master-Ausfall in AUTONOM.
- **WATER-NODE**: Hält geschlossenen Wasser-/Dampfkreislauf stabil und gleicht Defizite/Überschüsse aus.
- **ENERGY-NODE**: Liest Mekanism Energy Cubes / Induction Matrix und liefert Kapazität, Lade- und Entladeraten.
- **FUEL-NODE**: Verwaltert Fuel-Bestände (z. B. AE2), erzwingt Mindestreserve und führt Transfers nur per Master-Command aus.
- **REPROCESSOR-NODE**: Überwacht Waste-Puffer, meldet Outputs an FUEL-NODE und geht bei Master-Ausfall in sicheren Standby.

## Installationsanleitung
1. Kopiere den Ordner `xreactor` auf den Ziel-Computer.
2. Führe den Installer aus:
   ```
   cd /xreactor
   lua installer/installer.lua
   ```
3. Wähle die gewünschte Rolle, Modem-Seiten und eine Node-ID. Der Installer schreibt die passende `config.lua` und erstellt `startup.lua` für den Autostart.
4. Starte oder boote das System neu. MASTER kann ohne verbundene Nodes hochfahren.

## Erststart & Setup
1. Stelle sicher, dass alle Wireless- und Wired-Modems angebracht sind (MASTER nur Wireless zu Nodes, Wired zu Monitoren; Nodes Wired zu ihren Maschinen).
2. Verbinde MASTER per Kabel mit bis zu fünf Monitoren (Overview, RT Dashboard, Energy, Fuel/Water, Alarme).
3. Starte MASTER zuerst. RT-Nodes melden sich per `HELLO`, werden sequenziell hochgefahren (ACK → STABLE), danach folgen Telemetrie- und Alarmmeldungen.
4. Prüfe auf dem System Overview den Online-Status aller Nodes. Bei Bedarf Ziele (Power/Steam/RPM) anpassen.

## Sicherheitsprinzipien
- Zustandsmaschinen statt Event-Spam, Heartbeats mit Timeouts.
- Idempotente Commands (`SET_TARGET`-Logik, keine inkrementellen Befehle).
- Lokale Sicherheit hat Vorrang: RT-NODE darf immer limitieren, drosseln oder SCRAM auslösen.
- MASTER greift nie direkt auf Maschinen zu; Nodes kontrollieren nur ihre eigenen Peripherals.
- Caching von Peripherals, begrenzte Redraws der GUIs und minimale Polling-Intervalle.

## Troubleshooting
- **Keine Anzeige auf Monitor**: Prüfe Wired-Modem-Verbindung und Monitor-Side in `master/config.lua`.
- **Nodes offline**: Stelle sicher, dass Wireless-Kanal frei ist (Control 6500 / Status 6501) und Heartbeat-Intervalle nicht zu klein sind.
- **Reaktor-SCRAM**: RT-NODE ist in EMERGENCY; Temperaturgrenzen prüfen und ggf. `MODE=STARTUP` erneut senden.
- **Fuel unter Reserve**: Mindestreserve wird erzwungen; erhöhe Vorrat im Storage oder passe `minimum_reserve` an.

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz. Details siehe `LICENSE`.
