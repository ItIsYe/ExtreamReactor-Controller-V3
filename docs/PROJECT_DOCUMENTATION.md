# XReactor Controller V3 — Vollständige Projektdokumentation

> Letzte Aktualisierung: beta-v40  
> Stack: CC:Tweaked · Extreme Reactors 2 · Mekanism · ATM10 (MC 1.21.1)

---

## Inhaltsverzeichnis

1. [Systemüberblick](#1-systemüberblick)
2. [Netzwerk & Protokoll](#2-netzwerk--protokoll)
3. [MASTER Node](#3-master-node)
4. [RT Node — Reaktor & Turbinen](#4-rt-node--reaktor--turbinen)
5. [ENERGY Node](#5-energy-node)
6. [FUEL & REPROCESSING Node](#6-fuel--reprocessing-node)
7. [LOG Collector Node](#7-log-collector-node)
8. [WATER Node](#8-water-node)
9. [Installer & Manifest](#9-installer--manifest)
10. [Logger & Log-Transport](#10-logger--log-transport)
11. [node_id System](#11-nodeid-system)
12. [Ingame Konfiguration](#12-ingame-konfiguration)
13. [Bekannte Einschränkungen](#13-bekannte-einschränkungen)
14. [Changelog dieser Session](#14-changelog-dieser-session)

---

## 1. Systemüberblick

XReactor Controller V3 ist ein verteiltes Steuerungssystem für Extreme Reactors 2 und Mekanism-Infrastruktur. Das System besteht aus mehreren CC:Tweaked-Computern (Nodes), die über Ender-Modeme miteinander kommunizieren.

**Zentrales Design-Prinzip:** MASTER schickt nur Sollwerte und Absichten. Jeder RT-Node trifft lokale Hardware-Entscheidungen und schreibt selbst auf seine Peripherals. Kein anderer Node hat direkten Hardware-Write-Zugriff auf Reaktoren oder Turbinen.

### Physische Topologie

```
Alle Nodes ← Ender Modem → Drahtloses Netz (Kanäle 6500/6501/6502)

FUEL/REPROC → Wired Modem → Transporter/Reaktor-Ports (Logistics)
```

### Node-Rollen

| Rolle | Computer | Hauptaufgabe |
|-------|---------|-------------|
| MASTER | Advanced Computer | Koordination, UI, Setpoints |
| RT | Advanced Computer | Reaktor + Turbinen steuern |
| ENERGY | Advanced Computer | Mekanism-Matrix überwachen |
| FUEL | Advanced Computer | Brennstoff-Logistics |
| REPROCESSING | Advanced Computer | Waste-Verarbeitung |
| LOG | Advanced Computer | Log-Sammlung auf Disk |
| WATER | Advanced Computer | Wasser-Versorgung (Telemetrie) |

---

## 2. Netzwerk & Protokoll

### Modem-Kanäle

| Kanal | Richtung | Inhalt |
|-------|---------|--------|
| 6500 | MASTER → Nodes | Commands, Setpoints, Mode-Änderungen |
| 6501 | Nodes → MASTER | Telemetrie, Status, Heartbeat |
| 6502 | Nodes → LOG | Log-Events (UDP-artig mit ACK) |

### Nachrichtentypen (wichtigste)

- `SET_MODE` — AUTONOM/MASTER wechseln
- `SET_SETPOINTS` — Leistungsziel, RPM-Ziel, Turbinen-Assignment
- `STATUS` — Node sendet Telemetrie-Snapshot an MASTER
- `HEARTBEAT` — Lebenszeichen, wird für Offline-Erkennung genutzt
- `LOG_EVENT` / `LOG_ACK` — Zuverlässiger Log-Transport

### node_id — Netzwerk-Identität

Jeder Node hat eine stabile, eindeutige ID vom Format `node-<ComputerID>`, gespeichert in `/xreactor/config/node_id.txt`.

**Wichtig:** Die ID wird niemals vom Computer-Label abgeleitet. Labels (`XR-RT-54` etc.) sind rein kosmetisch. Wenn ein Node ständig als offline erscheint obwohl er läuft: Datei löschen und neu booten → ID wird neu generiert.

---

## 3. MASTER Node

### Aufgaben

- Empfängt Telemetrie von allen Nodes
- Berechnet Leistungsverteilung und Setpoints
- Sendet `SET_SETPOINTS` an RT-Nodes
- Zeigt System-UI auf angeschlossenen Monitoren
- Verwaltet Alarm-System und Node-Health

### Monitor-UI Tabs

| Tab | Inhalt |
|-----|--------|
| Overview | Gesamtsystem-Status, Energie, Alerts |
| RT-Dashboard | RT-Node Status, RPM, Kapazität |
| Energy | Matrix-Status, Füllstand |
| Alerts | Aktuelle Alarme |
| Logs | Log-Modus-Buttons |

### PC-Console-Fallback

Wenn kein externer Monitor angeschlossen ist, rendert MASTER auf das eigene Terminal. `monitor_manager.lua` erkennt das automatisch (`is_terminal = true`).

---

## 4. RT Node — Reaktor & Turbinen

Die RT-Node ist das Herzstück des Systems. Sie betreibt eine vollständig lokale Sicherheitsschleife, unabhängig vom MASTER.

### Startsequenz

```
1. Boot → 5s warten (LOG_COLLECTOR soll zuerst starten)
2. Peripherals entdecken (Reaktor + alle Turbinen)
3. CAPACITY LEARNING starten
4. Nach Lock: MASTER-Modus, Setpoints akzeptieren
```

### Capacity Learning — Ablauf

**Ziel:** Maximale Energieproduktion der Anlage messen, damit MASTER korrekte Prozent-Setpoints berechnen kann.

```
Lernphase:
├─ Reaktor: Stäbe auf 50% (bypassed regulator_min_rods-Konfiguration!)
├─ Turbinen: Alle 25 gleichzeitig auf 900 RPM regeln
├─ Warten bis 3 stabile Samples mit output > 0
└─ Lock → Cache speichern → Normale Regelung

Cache: /xreactor/config/capacity_cache.lua
  enthält: max_output (RF/t), turbine_count
  Invalidierung: wenn turbine_count sich ändert → Auto-Löschung + Re-Learning
```

**Wichtig:** Während des Learnings werden `SET_SETPOINTS`-Befehle vom MASTER abgelehnt (`CAPACITY_LEARNING not locked`). Das ist korrekt.

### Turbinen-Regelung (immer aktiv)

Jede Turbine bekommt jeden Tick individuell ihren Dampf-Flow geregelt — unabhängig vom Modul-State:

| Modul-State | Ziel-RPM | Ergebnis |
|---|---|---|
| `ON` | 900 RPM | Halten |
| `STARTING` | 900 RPM | Hochregeln |
| `nil` (Learning) | 900 RPM | Alle frei regeln |
| `OFF` | 0 RPM | Kontrolliert abbremsen, Coil aus |
| `ERROR` | 0 RPM | Sicher abbremsen |

Kein Turbinen-Zustand führt zu unkontrolliertem Laufen.

### Coil-Steuerung

- Einschalten bei: RPM ≥ 855
- Ausschalten bei: RPM < 750
- Overspeed-Schutz: Flow wird reduziert wenn RPM > 945

### Modul-State System

MASTER weist Turbinen über STARTUP_STAGE-Befehle zu:
- `OFF` → Turbine soll stoppen
- `STARTING` → Turbine soll hochfahren
- `ON` → Turbine läuft normal

Der Modul-State-Check greift **nur nach dem Capacity-Lock**. Während des Learnings laufen alle Turbinen frei.

### Reaktor-Regelung (Steam Margin)

Nach dem Capacity-Lock regelt der Steam-Margin-Regler die Reaktorstäbe basierend auf dem Dampfverbrauch der Turbinen. Während des Learnings ist der Steam-Margin-Regler pausiert.

### Node-States

```
INIT → AUTONOM (kein MASTER) 
     → MASTER (MASTER verbunden + Capacity gelocked)
     → LIMITED (Teillast)
     → EMERGENCY (SCRAM, Temperatur-Trip)
```

### Safety-Parameter (Defaults)

| Parameter | Wert |
|-----------|------|
| Reaktorstäbe normal | 80–98% |
| Reaktorstäbe SCRAM | 100% (bypassed alle Limits) |
| Reaktor Temperatur-Limit | 2000°C |
| Turbinen Ziel-RPM | 900 |
| Coil ein | 855 RPM |
| Coil aus | 750 RPM |
| Steam Guard high | 0.82 |
| Steam Guard critical | 0.92 |

### UI auf Monitor/Terminal

Tabs: Overview · Turbines · Reactors · Diagnostics (+ Log-Modus-Buttons)

---

## 5. ENERGY Node

### Aufgaben

- Überwacht Mekanism Induction Matrices
- Sendet Energie-Telemetrie an MASTER
- Matrix-API-Calls mit Budget-Kontrolle

### Konfiguration (wichtig)

```lua
matrix_component_time_budget_ms = 2000  -- Max Zeit für Matrix-API-Calls pro Tick
matrix_metric_call_budget = 6           -- Max teure API-Calls pro Payload
```

Der Zeit-Budget wurde auf 2000ms erhöht, da Mekanism-Matrix-Calls bis zu 1100ms dauern können.

### Ownership-Regel

- `nodes/energy/main.lua` = authoritative Runtime-Defaults
- `nodes/energy/config.lua` = installierbare/user-facing Template
- Änderungen an Defaults müssen in **beiden** Dateien gemacht werden

---

## 6. FUEL & REPROCESSING Node

### Logistics-System

Beide Nodes steuern Mekanism-Pipe-Ventile für gezieltes Material-Routing:

```
FUEL Node:      Brennstoff → spezifischer Reaktor
REPROC Node:    Waste → spezifischer Reprocessor
```

### Voraussetzungen

- **Wired Modem** für Peripheral-Zugriff (Transporter, Reaktor-Ports)
- **Ender Modem** für MASTER-Kommunikation
- Mekanism-Pipes auf **"High Redstone = Interrupt"** setzen

### Router-Konfiguration (ingame)

1. Monitor-Tab "Router" öffnen (oder PC-Terminal falls kein Monitor)
2. Pipe-Seite antippen → Ziel-Reaktor/Reprocessor antippen → Speichern
3. Routen gelten sofort (keine Neustart-Nötig)

Konfigurationsdateien:
- FUEL: `/xreactor/config/fuel_routes.lua`
- REPROCESSING: `/xreactor/config/reproc_routes.lua`

### Baum-Topologie (manuelle Konfiguration)

Für mehrere Verzweigungsebenen (Arm → Sub-Arm → Reaktor) direkt in der Config-Datei:

```lua
logistics = {
  redstone_tree = {
    { side = "right", label = "Arm A", children = {
        { side = "top",    label = "Reaktor 1", reactor = "BigReactors-Reactor_0" },
        { side = "bottom", label = "Reaktor 2", reactor = "BigReactors-Reactor_1" },
    }},
  },
  valve_open_ms = 2000,
}
```

---

## 7. LOG Collector Node

### Disk-Strategie

```
Disk A → voll → Disk B → voll → Disk C → voll
  → alle voll: Disk A leeren (alle Log-Dateien löschen) → von vorne
```

Externe Floppy-Disks/Drives werden automatisch erkannt. Fallback auf interne `/xreactor_collected_logs` wenn keine externe Disk vorhanden.

### Reliable Transport

- Jedes Log-Event hat `event_id = boot_id:seq` (reboot-sicher)
- Sender: max 3 Retry-Versuche, 30s Intervall zwischen Retries
- Collector: Deduplizierung per `event_id`, ACK nach erfolgreichem Write
- Bei Pause: Events werden nicht geschrieben, ACK wird zurückgehalten

### UI

| Anzeige | Bedeutung |
|---------|-----------|
| `Writing Disk #N` | Letzte erfolgreiche Schreibdisk |
| `* Disk A` | Aktive Schreibdisk (mit Sternchen) |
| `received / written / dup` | Transport-Statistik |
| `[PAUSE]/[RESUME]` | Disk-Write pausieren für Datei-Kopie |

Log-Modus-Buttons für den LOG Collector selbst (eigene Logs):
`[All][Disk][Rmt][Term][Off]` → Zeile 5 unter dem Pause-Button

---

## 8. WATER Node

Überwacht Wasser-Versorgung und sendet Telemetrie an MASTER. Keine eigene Hardware-Steuerung.

---

## 9. Installer & Manifest

### Ablauf

```
1. manifest.lua + release.lua von GitHub laden
2. Rolle auswählen (oder bestehende behalten)
3. Dateien aus manifest.lua nach required_for filtern
4. Staging: große Dateien zuerst (Platz-Optimierung)
5. Startup-Datei schreiben
6. Neustart
```

### required_for Rollen

Jede Manifest-Datei hat eine `required_for`-Liste. Nur gelistete Rollen installieren die Datei.

`nodes/support/ui_pages.lua` ist für alle Rollen erforderlich:
`WATER, FUEL, REPROCESSING, ENERGY, RT, MASTER`

### Manifest-Versionen

| Version | Inhalt |
|---------|--------|
| v29–v31 | Log-Modus-Buttons, PC-Fallback, Retry-Fix |
| v32 | Router-Dateien ins Manifest, Tote Dateien entfernt |
| v33 | node_id Label-Bug-Fix |
| v34 | ui_pages.lua für ENERGY/RT/MASTER |
| v35 | Logger disk_write_test Fix, RT term fallback |
| v36 | write_config kein Crash, Matrix-Budget 2000ms |
| v37 | RT CONTROL crash (runtime_ctx), UI-Timer-Fix |
| v38 | Module-State-Check bypass während Learning |
| v39 | STARTING-Turbinen jetzt geregelt |
| v40 | Flow-Regelung immer aktiv, target_rpm per State |

### Entwicklung: Manifest aktualisieren

```sh
python3 tools/regenerate_manifest_metadata.py
```

---

## 10. Logger & Log-Transport

### Log-Modi (alle Nodes)

Persistent gespeichert via CC `settings.set("xreactor.log_mode", mode)`.

| Modus | Verhalten |
|-------|-----------|
| `all` | Disk + Remote LOG (Standard) |
| `disk` | Nur lokale Disk |
| `remote` | Nur Remote LOG Collector |
| `terminal` | Nur Terminal-Ausgabe |
| `none` | Kein Logging |

### Logger-Stabilität

- Kein `error()` mehr in logger.lua → Node crasht nie wegen Logging
- `disk_error` wird nach erfolgreichem Write gecleart
- `disk_write_test()` nutzt lokale Variablen statt pcall-return (Lua-Bug-Fix)
- `utils.write_config()` gibt `false, reason` zurück statt zu crashen

### Startup-Delay

Alle Nodes außer `LOG` und `MASTER` warten 5 Sekunden nach dem Boot:
```
Waiting 5s for LOG_COLLECTOR to start... (role=RT)
  Starting in 5... 4... 3... 2... 1...
```

---

## 11. node_id System

### Priorität bei der ID-Auflösung

```
1. /xreactor/config/node_id.txt  (Single Source of Truth)
2. config.node_id (wenn gesetzt und kein Role-Default wie "RT-1")
3. node-<computerID>  (deterministisch, immer stabil)
```

Computer-Labels werden **nie** für die Netzwerk-ID verwendet. Labels sind menschlich lesbar (`XR-RT-54`), die Node-ID ist maschinenstabil (`node-52`).

### Troubleshooting: Node ständig offline

Wenn ein Node trotz normalem Betrieb immer wieder als offline erscheint:

```sh
delete /xreactor/config/node_id.txt
reboot
```

Die ID wird beim nächsten Boot sauber als `node-<ComputerID>` regeneriert.

---

## 12. Ingame Konfiguration

### Erste Installation

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
shell.run("/installer")
```

### Update (alle Nodes)

```sh
installer
```

### Wichtige Config-Dateien

| Datei | Inhalt |
|-------|--------|
| `/xreactor/config/role.lua` | Gewählte Rolle |
| `/xreactor/config/node_id.txt` | Netzwerk-ID des Computers |
| `/xreactor/config/capacity_cache.lua` | RT: gelernter max_output-Wert |
| `/xreactor/config/fuel_routes.lua` | FUEL: Ventil-Routing |
| `/xreactor/config/reproc_routes.lua` | REPROC: Ventil-Routing |

### RT: Re-Learning erzwingen

```sh
delete /xreactor/config/capacity_cache.lua
reboot
```

### Log-Modus ändern (per Befehl)

```lua
settings.set("xreactor.log_mode", "disk")  -- oder: all, remote, terminal, none
settings.save()
reboot
```

Oder: Diagnostics-Tab → Log-Modus-Button antippen.

---

## 13. Bekannte Einschränkungen

### node-54 (RT-Node)
- War ständig als offline sichtbar — Bug war Label-als-ID (jetzt behoben, v33)
- `/xreactor/config/node_id.txt` muss ggf. manuell gelöscht werden

### Log-Duplikate (~66%)
- Ursache: 25 Turbinen × 2 RT-Nodes auf einem Kanal → sehr hohes Nachrichten-Aufkommen
- Retry-Intervall auf 30s erhöht, MAX_SENDS auf 3 reduziert
- Duplikate sind nicht verlustreich — Collector dedupliziert korrekt

### Capacity-Learning Dauer
- Bei 25 Turbinen und voller Reaktorleistung: ca. 30–60 Sekunden
- Learning schlägt fehl wenn: Reaktor kalt, Dampf-Kapazität zu gering, Turbinen nicht ans Netz

---

## 14. Changelog dieser Session (beta-v29 → beta-v40)

### Kritische Bugfixes

**RT CONTROL crash beim SET_MODE MASTER (v37)**
`runtime_ctx` wurde in `get_turbine_module()` als Global (nil) angesehen, da `local runtime_ctx` erst nach der Funktion deklariert war. Fix: Forward-Declaration vor Zeile 49.

**RT Learning nie abgeschlossen — Deadlock (v38)**
20 von 25 Turbinen wurden im Modul-State-Check übersprungen (`STATE_OFF`), weil MASTER noch keine Setpoints geschickt hatte (er wartete auf Capacity-Lock → Deadlock). Fix: State-Check nur nach Capacity-Lock aktiv.

**Flow-Regelung in Blöcken statt einzeln (v39/v40)**
`STATE_STARTING`-Turbinen wurden komplett vom Regelkreis ausgeschlossen. `process_startup()` arbeitet immer nur eine Turbine gleichzeitig ab → 23 Turbinen ohne Kontrolle. Fix: Alle Turbinen immer regeln, State bestimmt nur die Ziel-RPM.

**Logger crasht bei Disk-Schreibfehler (v35/v36)**
`disk_write_test()` nutzte `pcall(function() return false end)` → Return-Werte ignoriert → Test immer OK → Write schlug lautlos fehl. Zudem: `utils.write_config()` warf `error()` → RT-Node-Crash beim Registry-Save.

**MASTER startet nicht (v33/v34)**
`render_log_mode_button()` nutzte `colors.black` als Global — nicht verfügbar im Bootstrap-Kontext → "bad argument (number expected, got string)". Fix: Explizite numerische CC-Farb-Konstanten. Zudem: `nodes/support/ui_pages.lua` fehlte im Manifest für ENERGY/RT/MASTER.

**node-54 ständig offline (v33)**
`resolve_node_id()` nutzte Computer-Label als Fallback-ID → Node meldete sich als `XR-RT-54` statt `node-52` → MASTER sah zwei Identitäten.

**Router-Dateien nie installiert (v32)**
`logistics_router.lua`, `redstone_router.lua`, `router_ui.lua` fehlten im Manifest → Installer lud sie nie → Router-Funktionalität komplett absent auf FUEL/REPROC-Nodes.

### Features

- **Log-Modus-Buttons** auf allen Nodes (Monitor + PC-Terminal): All/Disk/Rmt/Term/Off
- **PC-Console-Fallback** für alle Nodes ohne externen Monitor
- **Redstone-Router** für REPROCESSING Node (identisches Muster wie FUEL)
- **Capacity-Cache-Invalidierung** bei Turbinen-Anzahl-Änderung
- **Startup-Delay** 5s für alle Nodes außer LOG/MASTER
- **RT Monitor-Timer** unabhängig vom Control-Tick (0.5s, kein UI-Einfrieren)
- **LOG_COLLECTOR stay-on-disk** + Wipe-on-Wraparound

### Logging-Verbesserungen

- `disk_error` nach erfolgreichem Write gecleart
- Retry-Intervall 4s→8s→16s→30s (Log-Duplikate reduziert)
- MAX_SENDS 6→3 (weniger Kanal-Last)
- ENERGY Matrix-Budget 800ms→2000ms
