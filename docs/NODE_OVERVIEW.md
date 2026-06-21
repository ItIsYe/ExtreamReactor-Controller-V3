# XReactor Controller V3 — Node-Dokumentation

## Systemübersicht

Das System besteht aus 8 Nodes die über Ender-Modems auf drei Kanälen kommunizieren:

| Kanal | Zweck |
|-------|-------|
| 6500 | Control — Master → Nodes (Commands, Setpoints) |
| 6501 | Status — Nodes → Master (Heartbeat, Status-Payloads) |
| 6502 | Log — alle Nodes → Log-Collector |

---

## 1. MASTER (node-53)

**Rolle:** Koordinationszentrale. Empfängt Status aller Nodes, berechnet Setpoints und verteilt Leistung.

**Was er tut:**
- Empfängt HELLO/HEARTBEAT/STATUS von allen Nodes
- Verwaltet einen Node-Registry (`nodes[id]`) mit aktuellem Zustand jeder Node
- Berechnet globalen Energiebedarf aus Energy-Node Daten
- Verteilt Leistung auf RT-Nodes proportional zu ihrer gelockten Kapazität
- Startet RT-Nodes über den Startup-Sequencer (Module einzeln via STARTUP_STAGE)
- Rendert UI auf bis zu 3 Monitoren (Overview, RT-Dashboard, Energy)
- Erkennt SAFE/EMERGENCY/OFFLINE Nodes und reagiert entsprechend

**Wie es funktioniert:**
1. `runtime_loop.lua` — Haupt-Event-Loop, ruft Services pro Tick auf
2. `message_handlers.lua` — verarbeitet eingehende Nachrichten, aktualisiert `nodes[id]`
3. `rt_sync.lua` — berechnet pro RT-Node: Kapazität, assigned_percent, enable_reactors
4. `rt_sync_coalescer.lua` — bündelt Setpoint-Änderungen in 250ms Batch-Fenster
5. `startup_sequencer.lua` — startet Module einer RT-Node sequenziell, wartet auf ACK
6. `ui_controller.lua` — rendert Monitore, liest aggregierte Daten aus Node-Registry

**Wichtige Konfiguration:**
- `DEFAULT_NODE_OFFLINE_PURGE_AFTER_S = 120` — wann eine offline Node entfernt wird
- `DEFAULT_SEQUENCER_SCRAM_TEMPERATURE = 950` — Temperatur-Limit im Sequencer

---

## 2. RT-NODE (node-52, node-55, ...)

**Rolle:** Steuert einen Extreme-Reactors-2-Reaktor mit bis zu 25 Dampfturbinen.

**Was sie tut:**
- Entdeckt Reaktor und Turbinen via Peripheral-Discovery beim Start
- Führt Capacity-Learning durch: misst Output einer stabilen Turbine, rechnet auf alle hoch
- Regelt Reaktor-Stäbe via Steam-Margin-Regler (± 5% pro Schritt, alle 1,5s)
- Regelt Turbinen-RPM auf Ziel-RPM (Standard: 900 RPM) via Flow-Kontrolle
- Empfängt SET_SETPOINTS vom Master: `power_target_percent`, `enable_reactors`
- Verteilt Leistung auf Turbinen via Rotation-Offset (alle 5 Min gleichmäßig rotieren)
- Sendet alle 5s vollständigen Status-Payload an Master
- Rendert UI auf eigenem Monitor (Overview, Turbinen-Liste, Reaktor-Status)

**Wie es funktioniert:**

*Capacity-Learning:*
```
1. Turbinen hochfahren (Startup-Sequencer)
2. Warten bis ≥1 Turbine stabil (RPM in ±10% von Ziel, Coil engaged)
3. Sample messen: stable_output / stable_turbines × total_turbines
4. 3 valide Samples → Lock (max_output gespeichert in capacity_cache.lua)
5. Reset nur nach 3 aufeinanderfolgenden Fehlern (robust gegen Ausreißer)
```

*Rod-Regler (läuft immer, auch während Learning):*
```
steam_margin = verfügbarer_Dampf − Dampfbedarf_aller_Turbinen
Positiver Margin → Stäbe reinfahren (weniger Leistung)
Negativer Margin → Stäbe rausfahren (mehr Leistung)
Deadband: ±5000 mB | Schritt: max ±5% | Cooldown: 1,5s
Regelbereich: 80–100% Insertion
```

*Turbinen-Regelung:*
```
Ziel-RPM = base_rpm × (power_target_percent / 100) × Turbinen-Anteil
Flow-Regler: erhöht/senkt Dampf-Input bis Ziel-RPM erreicht
Coil: klinkt sich automatisch bei ~900 RPM ein
Rotation-Offset: alle 5 Min rotiert welche Turbinen Vollast haben
```

**Wichtige Konfiguration:**
- `TARGET_RPM = 900` — Ziel-RPM für alle Turbinen
- `ROD_MAX = 100`, `ROD_MIN = 80` — Regelbereich
- `INITIAL_ROD_LEVEL = 98` — Startwert beim allerersten Boot

---

## 3. ENERGY-NODE (node-54, 56, 57, 58)

**Rolle:** Überwacht Mekanism-Energiematrizen und Energiespeicher, meldet Füllstand an Master.

**Was sie tut:**
- Entdeckt automatisch alle Induction-Matrix-Ports und Energiespeicher
- Liest alle 3s: stored RF, capacity RF, input RF/t, output RF/t pro Matrix
- Aggregiert mehrere Matrizen zu einem Gesamt-Snapshot
- Sendet alle 5s Status-Payload an Master (stored_percent, input, output)
- Rendert UI mit Füllstand-Balken und aktuellen Werten

**Wie es funktioniert:**
1. `discovery_runtime.lua` — sucht alle Peripherals, erkennt Matrix-Ports dynamisch
2. Matrix-Adapter liest via `getEnergy()`, `getMaxEnergy()`, `getEnergyFilledPercentage()`
3. Mehrere Matrix-Ports werden zu einer logischen Matrix gruppiert
4. `status_payload` — aggregiert stored/capacity/input/output für Master

**Wichtige Konfiguration:**
- `matrix_metric_poll_interval = 3.0s` — Abfrageintervall
- Matrix-Namen optional konfigurierbar (sonst Auto-Discovery)

---

## 4. FUEL-NODE

**Rolle:** Verwaltet Brennstoff-Logistik zwischen ME-System und Extreme-Reactors-2-Reaktoren.

**Was sie tut:**
- Verbindet sich via Wired Modem direkt mit ER2-Reaktor-Computer-Ports
- Liest Brennstoff-Level direkt vom Reaktor (`getFuelStats()`, `getFuelAmount()`)
- Exportiert Brennstoff aus ME-System wenn Reaktor unter `request_below`-Schwelle fällt
- Öffnet Redstone-gesteuerte Ventile (Mekanism Logistical Transporter) temporär (2s)
- Schließt alle anderen Ventile während Export (nur Ziel-Ventil offen)
- Sammelt Reaktor-Abfall aus Outlet-Transportern zurück ins ME-System
- Empfängt SET_RESERVE-Commands vom Master (ändert Mindest-Reserve)

**Wie es funktioniert:**

*Export-Flow:*
```
1. Alle konfigurierten Reaktoren prüfen (alle N Sekunden)
2. Reaktor A: fuel_ratio < request_below (z.B. 0.25)?
3. Berechne push = min(fill_amount, in_me - min_in_me)
4. Redstone-Route öffnen (nur Reaktor-A-Ventil HIGH→LOW = offen)
5. ME-Bridge: exportItemToPeripheral(item, inlet, count=push)
6. 2000ms warten → Ventil schließen
7. Weiter mit Reaktor B, C, ...
```

*Waste-Collection:*
```
1. Outlet-Transporter alle N Sekunden prüfen
2. Items aus Outlet ins ME-System importieren
3. Zählt importierte Abfall-Items im Status
```

**Wichtige Konfiguration:**
```lua
logistics = {
  me_bridge       = "me_bridge",      -- ME-Bridge Peripheral-Name
  reactors = {
    { reactor_port  = "BigReactors-Reactor_0",
      inlet         = "mekanism:transporter_0",
      item          = "bigreactors:yellorium_ingot",
      request_below = 0.25,           -- Export wenn Füllstand < 25%
      fill_amount   = 64,             -- Items pro Export
      min_in_me     = 128 }           -- ME-Reserve nicht unterschreiten
  },
  redstone_routes = {
    { reactor = "RT-1", side = "right" }
  }
}
```

---

## 5. WATER-NODE

**Rolle:** Überwacht und hält Kühlwasser-Tanks (Mekanism Dynamic Tank) auf Ziel-Volumen.

**Was sie tut:**
- Entdeckt automatisch Dynamic-Tank-Peripherals
- Liest Füllstand via `tanks()` oder `getFluidAmount()` (je nach Adapter)
- Meldet aktuellen Stand an Master (stored, capacity, percent)
- Fordert Befüllung an wenn Füllstand < `target_volume`
- Warnt wenn Füllstand > 110% des Ziels (Überlauf)
- Rendert UI mit Füllstand-Balken

**Wie es funktioniert:**
```
Alle 5s:
1. Füllstand lesen (safe_wrapped_call → pcall-geschützt)
2. total < target_volume → "Refill requested: X mB" loggen
3. total > target_volume × 1.1 → "Bleed excess" loggen
4. Status-Payload senden: stored, capacity, target, percent
```

**Wichtige Konfiguration:**
- `target_volume = 200000` — Ziel-Volumen in mB
- `balance_log_interval_s = 60` — Log-Intervall für Befüllungs-Meldungen

---

## 6. REPROCESSOR-NODE

**Rolle:** Überwacht Wiederaufbereitungs-Puffer (Mekanism Chemical Tanks) und triggert Verarbeitung.

**Was sie tut:**
- Entdeckt automatisch Chemical-Tank-Peripherals (`chemical_tank_0`, etc.)
- Liest Puffer-Stand pro Tank (via `getBuffer()`, `getStored()`, oder direkte API)
- Ruft `process()` auf jedem Tank auf wenn verfügbar (pcall-geschützt)
- Meldet Puffer-Stände und Auslastung an Master
- Empfängt MODE-Commands (active/standby) vom Master
- Rendert UI mit Puffer-Balken pro Tank

**Wie es funktioniert:**
```
Alle 5s:
1. Alle konfigurierten Buffer-Peripherals scannen
2. Pro Tank: stored + capacity lesen
3. process() aufrufen wenn vorhanden (startet Wiederaufbereitung)
4. Aggregierten Status an Master senden
```

**Wichtige Konfiguration:**
- `buffers = {"chemical_tank_0"}` — Liste der zu überwachenden Tanks

---

## 7. SUPPORT-NODE

**Rolle:** Framework-Node für einfache Monitoring-/Steuerungs-Aufgaben ohne eigene Kern-Logik.

**Was sie tut:**
- Stellt gemeinsame Laufzeit-Funktionen für andere Nodes bereit:
  - `run_event_loop()` — Haupt-Event-Loop mit xpcall-Crash-Handler
  - `safe_wrapped_call()` — pcall-Wrapper für Peripheral-API-Calls
  - `init_logging()` — Logger-Initialisierung
  - `warn_once()` — einmaliges Warnen bei wiederholten Fehlern
- Eigene Support-Node: empfängt Commands, führt Redstone-Operationen aus
- Discovery: sucht und registriert Peripherals beim Start

**Wie es funktioniert:**
```
Shared Runtime (genutzt von fuel/water/reprocessor):
  M.run_event_loop(interval, services, comms, after_cycle)
    └→ xpcall(main_loop) → crash_screen + os.reboot() bei Fehler
    └→ pcall(after_cycle) → Fehler werden geloggt, Loop läuft weiter

Support-Node selbst:
  1. Discovery: alle Peripherals finden
  2. Commands via handle_common() empfangen
  3. Redstone-Outputs setzen auf Command
  4. Status an Master senden
```

---

## 8. LOG-COLLECTOR (node-62)

**Rolle:** Empfängt Log-Nachrichten aller Nodes zentral und schreibt sie auf Disk.

**Was er tut:**
- Lauscht auf Kanal 6502 für LOG_EVENT-Nachrichten aller Nodes
- Schreibt Logs sortiert nach Node-ID in separate Dateien
- Sendet ACK zurück an Sender (für Retry-Logik)
- Rotiert Log-Dateien bei Überschreitung der Größengrenze
- Wipe beim Start: löscht alle alten Log-Dateien
- Unterstützt Ring-Buffer über mehrere Disks

**Wie es funktioniert:**
```
Beim Start:
  1. Alle angeschlossenen Disks finden
  2. Alte Logs löschen (wipe_logs)
  3. Auf Kanal 6502 lauschen

Pro empfangene Log-Nachricht:
  1. node_id aus Payload → Dateiname bestimmen
     z.B. "pc-52" → /disk/pc-52.log
  2. In Datei schreiben: [timestamp] ROLE | PREFIX | LEVEL | message
  3. Dateigröße > 512KB → rotate (→ .log.1 → .log.2 → ... → .log.5 → löschen)
  4. ACK zurück senden

Disk-Verwaltung:
  Ring-Buffer: wechselt Disk wenn < 64KB frei
  Fallback: lokaler Pfad wenn keine Disk angeschlossen
```

**Wichtige Konfiguration:**
- `MAX_LOG_BYTES = 524288` (512 KB pro Datei)
- `ROTATE_KEEP = 5` (5 Rotationen = max 2,5 MB pro Node)
- `MIN_FREE_BYTES = 65536` (64 KB Mindest-Freispeicher)

---

## Kommunikations-Ablauf beim Start

```
T+0s   Alle Nodes starten mit 5s Boot-Delay
T+5s   Nodes senden HELLO → Master registriert sie
T+5s   Master → RT-Node: SET_MODE MASTER
T+6s   Startup-Sequencer enqueued RT-Node
T+10s  Master → STARTUP_STAGE (Turbine 1)
T+15s  RT-Node: Turbine 1 started → ACK_APPLIED
T+...  Weitere Turbinen werden gestartet
T+Nm   Capacity-Learning abgeschlossen → locked
T+Nm   Master empfängt capacity_ready=true
T+Nm   Master berechnet assigned_percent → SET_SETPOINTS
T+Nm   RT-Node: normaler Betrieb mit Rod-Regler
```

---

## Installer

Der Installer (`installer` Datei im Root) ist ein selbständiger Bootstrap:
1. Lädt `installer_main.lua` und weitere Module von GitHub
2. Lässt den Nutzer eine Rolle auswählen (oder erkennt bestehende)
3. Lädt alle Dateien laut Manifest herunter
4. Validiert jeden Hash (CRC32) vor dem Commit
5. Schreibt `/startup` für automatischen Start
6. **Setzt `xreactor.log_mode = "all"`** in CC:Tweaked Settings (seit v71)
7. Rebooted nach erfolgreichem Install
