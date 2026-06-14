# XReactor Controller V3 — Vollständige Projektdokumentation

> Letzte Aktualisierung: beta-v43  
> Stack: CC:Tweaked · Extreme Reactors 2 · Mekanism · ATM10 (MC 1.21.1)

---

## Inhaltsverzeichnis

1. [Systemüberblick](#1-systemüberblick)
2. [Designprinzip: maximale Effizienz](#2-designprinzip-maximale-effizienz)
3. [Netzwerk & Protokoll](#3-netzwerk--protokoll)
4. [MASTER Node](#4-master-node)
5. [RT Node — Reaktor & Turbinen](#5-rt-node--reaktor--turbinen)
6. [ENERGY Node](#6-energy-node)
7. [FUEL & REPROCESSING Node](#7-fuel--reprocessing-node)
8. [LOG Collector Node](#8-log-collector-node)
9. [WATER Node](#9-water-node)
10. [Installer & Manifest](#10-installer--manifest)
11. [Logger & Log-Transport](#11-logger--log-transport)
12. [node_id System](#12-nodeid-system)
13. [Ingame Konfiguration](#13-ingame-konfiguration)
14. [Bekannte Einschränkungen](#14-bekannte-einschränkungen)
15. [Changelog beta-v29 → beta-v43](#15-changelog-beta-v29--beta-v43)

---

## 1. Systemüberblick

XReactor Controller V3 ist ein verteiltes Steuerungssystem für Extreme Reactors 2 und Mekanism-Infrastruktur. Das System besteht aus mehreren CC:Tweaked-Computern (Nodes), die über Ender-Modeme miteinander kommunizieren.

**Zentrales Design-Prinzip:** MASTER schickt nur Sollwerte und Absichten. Jeder RT-Node trifft lokale Hardware-Entscheidungen und schreibt selbst auf seine Peripherals. Kein anderer Node hat direkten Hardware-Write-Zugriff auf Reaktoren oder Turbinen.

### Node-Rollen

| Rolle | Computer | Hauptaufgabe |
|-------|---------|-------------|
| MASTER | Advanced Computer | Koordination, UI, Setpoints |
| RT | Advanced Computer | Reaktor + Turbinen steuern |
| ENERGY | Advanced Computer | Mekanism-Matrix überwachen |
| FUEL | Advanced Computer | Brennstoff-Logistics |
| REPROCESSING | Advanced Computer | Waste-Verarbeitung |
| LOG | Advanced Computer | Log-Sammlung auf Disk |
| WATER | Advanced Computer | Wasser-Versorgung |

---

## 2. Designprinzip: maximale Effizienz

Das gesamte Steuerungssystem ist auf **maximale Energieeffizienz** ausgelegt. Der wichtigste Parameter ist die Turbinen-RPM.

### Warum immer 900 RPM?

**900 RPM ist das Effizienzoptimum für Extreme Reactors 2 Turbinen.** Bei genau 900 RPM wandelt die Turbine Dampf mit maximalem Wirkungsgrad in RF um. Darunter steigt der spezifische Dampfverbrauch pro RF — die Turbine produziert weniger Strom pro Dampfeinheit.

Konsequenz: Es gibt **keinen sinnvollen Betrieb bei Teildrehzahl**. Eine Turbine bei 450 RPM ist ineffizienter als gar nicht zu laufen, weil sie Dampf verbraucht aber weniger Strom erzeugt.

### Coil-Engagement und Stromerzeugung

Der Generator-Coil (Induktor) erzeugt erst ab einer bestimmten Drehzahl nutzbar Strom:

| RPM | Coil-Zustand | Stromerzeugung |
|-----|-------------|----------------|
| ≥ 900 | Einschalten | Ja, maximale Effizienz |
| 850–899 | Zustand halten | Ja (wenn vorher eingeschaltet) |
| < 850 | Ausschalten | Nein |

**RPM-Skalierung funktioniert nicht für Leistungsreduzierung:** Eine Turbine bei 450 RPM hat keinen engagierten Coil → kein Strom → schlechter als stoppen.

### Leistungsregelung: immer über Turbinen-Anzahl

Das einzige effiziente Verfahren zur Leistungsreduzierung ist das **Stoppen von Turbinen**:

```
Leistung 80%  →  20 von 25 Turbinen bei 900 RPM (Coil AN)
                  5 von 25 Turbinen bremsen auf 0 (Coil AUS)

Leistung 50%  →  13 von 25 Turbinen bei 900 RPM (Coil AN)
                 12 von 25 Turbinen bremsen auf 0 (Coil AUS)
```

Jede laufende Turbine läuft immer bei 900 RPM (Effizienzoptimum). Nur die Anzahl der laufenden Turbinen ändert sich.

---

## 3. Netzwerk & Protokoll

### Modem-Kanäle

| Kanal | Richtung | Inhalt |
|-------|---------|--------|
| 6500 | MASTER → Nodes | Commands, Setpoints |
| 6501 | Nodes → MASTER | Telemetrie, Heartbeat |
| 6502 | Nodes → LOG | Log-Events |

### Physische Topologie

```
Alle Nodes ← Ender Modem → Drahtloses Netz (Kanäle 6500/6501/6502)
FUEL/REPROC → Wired Modem → Transporter/Reaktor-Ports (Logistics)
```

### node_id — Netzwerk-Identität

Jeder Node hat eine stabile ID `node-<ComputerID>` in `/xreactor/config/node_id.txt`. Niemals vom Computer-Label abgeleitet (Labels sind nur menschlich lesbar).

---

## 4. MASTER Node

Koordiniert alle Nodes, berechnet Leistungsverteilung, zeigt System-UI.

### Monitor-UI Tabs

| Tab | Inhalt |
|-----|--------|
| Overview | Gesamtsystem, Energie, Alerts |
| RT-Dashboard | RT-Status, RPM, Kapazität |
| Energy | Matrix-Status |
| Alerts | Alarme |
| Logs | Log-Modus-Buttons |

Wenn kein externer Monitor: Fallback auf Terminal (`monitor_manager.lua`).

---

## 5. RT Node — Reaktor & Turbinen

Die RT-Node betreibt eine vollständig lokale Sicherheitsschleife, unabhängig vom MASTER.

### Startsequenz

```
1. Boot → 5s warten (LOG_COLLECTOR soll zuerst starten)
2. Peripherals entdecken (Reaktor + alle Turbinen)
3. CAPACITY LEARNING
4. Nach Lock: MASTER-Modus aktiv
```

### Capacity Learning

**Ziel:** Maximale Energieproduktion der Anlage messen.

```
Lernphase:
├─ Reaktorstäbe: 50% (bypassed regulator_min_rods-Konfiguration!)
├─ ALLE Turbinen gleichzeitig auf 900 RPM regeln
├─ 3 stabile Samples mit output > 0 → LOCK
└─ Cache: /xreactor/config/capacity_cache.lua
           (enthält max_output und turbine_count)

Cache-Invalidierung: automatisch wenn turbine_count sich ändert
```

Während des Learnings werden `SET_SETPOINTS`-Befehle abgelehnt — das ist korrekt.

### Turbinen-Regelkreis — immer geschlossen

Der Regelkreis läuft für **jede Turbine, jeden Tick**, ohne Ausnahme. Kein State, kein Modus, kein MASTER-Befehl kann die Regelung abschalten. Nur der **Zielwert** ändert sich:

```
Lernphase (alle):           Ziel = 900 RPM → Coil AN bei 900
Aktive Turbine (im Budget): Ziel = 900 RPM → Coil AN bei 900
Inaktive Turbine (zu viel): Ziel =   0 RPM → Coil AUS wenn RPM < 850
Fehler-State:               Ziel =   0 RPM → Coil AUS
```

### Automatische Leistungsregelung

```
Berechnung:
  active_count = round(Anzahl_Turbinen × power_percent / 100)
  Reihenfolge: stabil nach Index in config.turbines

Beispiel (25 Turbinen):
  power_percent = 80%  →  active_count = 20
    Turbine  1–20: Ziel 900 RPM (Coil engagiert bei 900 → Strom)
    Turbine 21–25: Ziel   0 RPM (Coil aus bei < 850     → kein Strom)

  power_percent = 50%  →  active_count = 13
    Turbine  1–13: 900 RPM, Coil AN
    Turbine 14–25:   0 RPM, Coil AUS

  power_percent = 100% →  alle 25 bei 900 RPM
  power_percent =   0% →  alle 25 bremsen auf 0
```

Warum nicht RPM-Skalierung: Coil engagiert sich erst bei ≥ 900 RPM. Eine Turbine bei 450 RPM erzeugt keinen Strom. Daher ist Turbinen-Anzahl immer effizienter.

### Coil-Schwellwerte

```
Einschalten:  RPM ≥ 900  (am Zielwert)
Halten:       RPM 850–899 (Hysterese, kein Wechsel)
Ausschalten:  RPM < 850
```

### Steam Margin — Reaktor-Regelung

Nach dem Capacity-Lock regelt der Steam-Margin-Regler die Reaktorstäbe:

```
steam_margin = verfügbarer_Dampf − gesamter_Dampfbedarf_aller_Turbinen
Positiver Margin → Reaktorstäbe schließen (weniger Dampf)
Negativer Margin → Reaktorstäbe öffnen  (mehr Dampf)
```

Während des Learnings ist der Steam-Margin-Regler pausiert (Stäbe bleiben bei 50%).

### Node-States

| State | Bedeutung |
|-------|-----------|
| `INIT` | Bootstrap, noch keine Peripherals |
| `AUTONOM` | Kein MASTER verbunden, lokaler Betrieb |
| `MASTER` | MASTER verbunden, Capacity gelocked |
| `LIMITED` | Teillast |
| `EMERGENCY` | SCRAM/Temperatur-Trip, Stäbe auf 100% |

### Safety-Parameter (Defaults)

| Parameter | Wert | Grund |
|-----------|------|-------|
| Turbinen Ziel-RPM | 900 | Effizienzoptimum ER2 |
| Coil einschalten | ≥ 900 RPM | Am Zielwert |
| Coil ausschalten | < 850 RPM | Hysterese-Band |
| Reaktorstäbe normal | 80–98% | Regelbereich |
| Reaktorstäbe SCRAM | 100% | Bypassed alle Limits |
| Reaktor Temperatur-Limit | 2000°C | Hardware-Schutz |
| Steam Guard high | 0.82 | Vorwarnung |
| Steam Guard critical | 0.92 | Notabschaltung |

---

## 6. ENERGY Node

Überwacht Mekanism Induction Matrices und sendet Energie-Telemetrie.

### Matrix-Budget

```lua
matrix_component_time_budget_ms = 2000  -- Max Zeit pro Tick (Mekanism-API langsam)
matrix_metric_call_budget = 6           -- Max API-Calls pro Payload
```

### Ownership-Regel
- `nodes/energy/main.lua` = authoritative Runtime-Defaults
- `nodes/energy/config.lua` = installierbare/user-facing Template

---

## 7. FUEL & REPROCESSING Node

### Redstone-Ventil-Routing

```
Voraussetzungen:
  - Wired Modem für Peripheral-Zugriff
  - Ender Modem für MASTER-Kommunikation
  - Mekanism-Pipes: "High Redstone = Interrupt"

Konfiguration (ingame):
  Monitor-Tab "Router" → Pipe-Seite antippen → Ziel antippen → Speichern
  (auch ohne Monitor: PC-Terminal mit Maus-Klick)

Config-Dateien:
  FUEL:         /xreactor/config/fuel_routes.lua
  REPROCESSING: /xreactor/config/reproc_routes.lua
```

### Baum-Topologie (manuelle Config)

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

## 8. LOG Collector Node

### Disk-Strategie

```
Disk A → voll → Disk B → voll → Disk C → voll
  → alle voll: Disk A leeren → von vorne (Ring-Buffer)
MIN_FREE_BYTES = 8192
```

### Reliable Transport

| Eigenschaft | Wert |
|-------------|------|
| Event-ID | `boot_id:seq` (reboot-sicher) |
| Max Retries | 3 |
| Retry-Intervall | 30s |
| Deduplizierung | per event_id |
| ACK | nach erfolgreichem Write |

### UI-Anzeige

| Element | Bedeutung |
|---------|-----------|
| `Writing Disk #N` | Letzte erfolgreiche Disk |
| `* Disk A` | Aktive Disk (Sternchen) |
| `received/written/dup` | Transport-Statistik |
| `[PAUSE]/[RESUME]` | Disk-Write für Datei-Kopie pausieren |

Log-Modus-Buttons (Zeile 5, für eigene Logs des LOG-Node):
`[All][Disk][Rmt][Term][Off]`

---

## 9. WATER Node

Telemetrie-Node für Wasser-Versorgung. Keine eigene Hardware-Steuerung.

---

## 10. Installer & Manifest

### Ablauf

```
1. manifest.lua + release.lua von GitHub laden
2. Rolle auswählen (oder bestehende behalten)
3. Dateien nach required_for filtern
4. Staging: große Dateien zuerst
5. /startup schreiben → Neustart
```

### Manifest-Versionen (Auszug)

| Version | Hauptänderungen |
|---------|----------------|
| v29–v31 | Log-Modus-Buttons, PC-Fallback, Retry-Fix |
| v32 | Router-Dateien ins Manifest aufgenommen |
| v33 | node_id Label-Bug-Fix (node-54 offline) |
| v34 | ui_pages.lua für ENERGY/RT/MASTER |
| v35 | Logger disk_write_test Fix, RT term-Fallback |
| v36 | write_config kein Crash, Matrix-Budget 2000ms |
| v37 | RT CONTROL crash (runtime_ctx forward-decl), UI-Timer |
| v38 | Modul-State-Check bypass während Learning |
| v39 | STARTING-Turbinen werden jetzt geregelt |
| v40 | Flow-Regelung immer aktiv, target_rpm per State |
| v41 | Coil 900/850, updateControl ohne State-Guard |
| v42 | power_percent → target_rpm Übersetzung |
| v43 | Automatische Turbinen-Anzahl-Steuerung mit Coil-Awareness |

---

## 11. Logger & Log-Transport

### Log-Modi

| Modus | Verhalten |
|-------|-----------|
| `all` | Disk + Remote LOG (Standard) |
| `disk` | Nur lokale Disk |
| `remote` | Nur Remote LOG Collector |
| `terminal` | Nur Terminal |
| `none` | Kein Logging |

Persistent via CC `settings.set("xreactor.log_mode", mode)`.

### Wichtige Bugfixes

- `disk_write_test()`: pcall-return-Bug behoben (Lua ignoriert innere Returns) → Logger schreibt jetzt korrekt auf Disk
- `utils.write_config()`: kein `error()` mehr → RT crasht nie beim Registry-Save
- `disk_error` wird nach erfolgreichem Write gecleart
- Retry-Intervall: 4s → 8s → 16s → 30s (Duplikate reduziert)

### Startup-Delay

Alle Nodes außer `LOG` und `MASTER` warten 5s beim Boot.

---

## 12. node_id System

### Priorität

```
1. /xreactor/config/node_id.txt  → Single Source of Truth
2. config.node_id               → wenn kein Role-Default (z.B. "RT-1")
3. node-<computerID>            → immer stabil, nie vom Label
```

Computer-Labels (`XR-RT-54`) sind nur menschlich lesbar. Die Netzwerk-ID ist immer `node-<ComputerID>`.

### Troubleshooting: Node offline

```sh
delete /xreactor/config/node_id.txt
reboot
```

---

## 13. Ingame Konfiguration

### Installation

```sh
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer
shell.run("/installer")
```

### Update

```sh
installer
```

### Wichtige Config-Dateien

| Datei | Inhalt |
|-------|--------|
| `/xreactor/config/role.lua` | Gewählte Rolle |
| `/xreactor/config/node_id.txt` | Netzwerk-ID |
| `/xreactor/config/capacity_cache.lua` | RT: max_output + turbine_count |
| `/xreactor/config/fuel_routes.lua` | FUEL: Ventil-Routing |
| `/xreactor/config/reproc_routes.lua` | REPROC: Ventil-Routing |

### Re-Learning erzwingen

```sh
delete /xreactor/config/capacity_cache.lua
reboot
```

### Log-Modus (per Befehl)

```lua
settings.set("xreactor.log_mode", "disk")
settings.save()
reboot
```

---

## 14. Bekannte Einschränkungen

### Log-Duplikate (~30–40% nach Optimierung)

25 Turbinen × 2 RT-Nodes auf einem Kanal → hohes Nachrichtenaufkommen. Duplikate sind nicht verlustreich — Collector dedupliziert korrekt. Retry-Intervall auf 30s erhöht.

### Kapazitäts-Learning Voraussetzungen

Learning schlägt fehl wenn:
- Reaktor kalt gestartet wird
- Dampf-Kapazität für 25 Turbinen nicht ausreicht
- Turbinen nicht physisch angeschlossen sind

### Integer-Schritte bei Turbinen-Anzahl

Bei 25 Turbinen gibt es 26 diskrete Leistungsstufen (0%, 4%, 8%, ..., 100%). Zwischen diesen Stufen ist keine feinstufigere Regelung möglich ohne RPM-Skalierung (die aber keinen Strom erzeugt). Für feine Leistungsregelung: mehr Turbinen verwenden.

---

## 15. Changelog beta-v29 → beta-v43

### Kritische Bugfixes

**RT CONTROL crash beim SET_MODE MASTER (v37)**
`runtime_ctx` war in `get_turbine_module()` als Global (nil) sichtbar — forward-declaration vor Zeile 49 fehlte. Fix: `local runtime_ctx` forward-deklariert.

**RT Learning nie abgeschlossen — Deadlock (v38)**
20/25 Turbinen wurden übersprungen (`STATE_OFF`) da MASTER keine Setpoints schicken konnte (wartete auf Capacity-Lock → Deadlock). Fix: Modul-State-Check nur nach Capacity-Lock.

**Turbinen in Blöcken, nicht einzeln (v39/v40/v41)**
`STATE_STARTING`-Turbinen wurden komplett übersprungen. `process_startup()` verarbeitete nur eine Turbine gleichzeitig → 23 unkontrolliert. Fix: alle Turbinen immer regeln.

**Logger crasht bei Disk-Schreibfehler (v35/v36)**
`disk_write_test()` nutzte `pcall(function() return false end)` — Lua ignoriert innere Return-Werte → Test immer OK. `utils.write_config()` warf `error()` → RT-Node-Crash. Beides behoben.

**MASTER startet nicht (v33/v34)**
`render_log_mode_button()` nutzte `colors.black` als Global — nicht verfügbar im Bootstrap. Fix: explizite CC-Farb-Zahlen (`CC_BLACK=32768` etc.). `ui_pages.lua` fehlte im Manifest für ENERGY/RT/MASTER.

**node-54 ständig offline (v33)**
`resolve_node_id()` nutzte Computer-Label (`XR-RT-54`) als Fallback-ID. MASTER sah zwei Identitäten. Fix: nur `node-<ComputerID>`, nie Label.

**Router-Dateien nie installiert (v32)**
`logistics_router.lua`, `redstone_router.lua`, `router_ui.lua` fehlten im Manifest → Installer lud sie nie. Fix: ins Manifest aufgenommen mit `required_for={FUEL,REPROCESSING}`.

### Features

| Feature | Version |
|---------|---------|
| Log-Modus-Buttons auf allen Nodes | v29/v30 |
| PC-Console-Fallback (kein Monitor nötig) | v29/v30 |
| Redstone-Router für REPROCESSING | v31 |
| Capacity-Cache-Invalidierung bei Turbinen-Änderung | v28 |
| Startup-Delay 5s (LOG zuerst) | v29 |
| RT Monitor-Timer unabhängig vom Control-Tick | v37 |
| LOG_COLLECTOR stay-on-disk + Wipe-on-Wraparound | v29 |
| Turbinen immer einzeln geregelt, Coil 900/850 | v41 |
| Automatische Turbinen-Anzahl-Steuerung | v43 |
