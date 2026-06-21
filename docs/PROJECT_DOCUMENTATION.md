# XReactor Controller V3 — Vollständige Projektdokumentation

> Letzte Aktualisierung: beta (aktuelle Session)
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

**900 RPM ist das Effizienzoptimum für Extreme Reactors 2 Turbinen.** Bei genau 900 RPM wandelt die Turbine Dampf mit maximalem Wirkungsgrad in RF um. Unterhalb von 900 RPM ist der Coil nicht eingeklinkt — die Turbine verbraucht Dampf erzeugt aber keinen Strom.

### Coil-Engagement und Stromerzeugung

Der Generator-Coil (Induktor) skaliert seine Einschalt- und Ausschaltschwellen proportional zur Ziel-RPM:

| Betrieb | Ziel-RPM | Einschalten | Ausschalten |
|---------|----------|-------------|-------------|
| Vollast | 900 | ≥ 900 RPM | < 850 RPM |
| Teillast 50% | 450 | ≥ 450 RPM | < 425 RPM |
| Stop | 0 | — (austrudeln) | — |
| Overspeed | any | > Ziel + 20 RPM → Coil FORCE ON (mitreißen) | — |

### Leistungsregelung: Turbinen-Anzahl zuerst, Teillast als Fallback

```
Nachfrage = Anzahl_Turbinen × power_percent / 100

Vollast-Turbinen  = floor(Nachfrage)  → 900 RPM, Coil nach Schwelle
Teillast-Turbine  = 1 (falls Restteil > 1%)  → anteilige RPM, Coil skaliert
Stop-Turbinen     = Rest  → 0 RPM, austrudeln

Beispiel: 25 Turbinen, 54% → Nachfrage = 13.5
  13 Turbinen bei 900 RPM  (Coil AN bei ≥ 900)
   1 Turbine  bei 450 RPM  (Coil AN bei ≥ 450, AUS bei < 425)
  11 Turbinen trudeln aus   (flow = 0)
```

**Rotation:** Alle 5 Minuten rotiert ein `rotation_offset` die Zuweisung über alle physischen Turbinen-Positionen. Jede Turbine trägt alle Rollen gleichmäßig — vollständig unabhängig von der Turbinen-Anzahl pro Node (1 bis N).

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

### Setpoint-Verteilung

Der Master berechnet einmal pro Sync-Zyklus einen Plan für alle RT-Nodes:

```
global_target (RF/t)
  → aufgeteilt nach node.capacity_max pro Node
  → assigned_percent = min(100, assigned_power / capacity_max × 100)
  → gesendet als SET_SETPOINTS an jeden Node
```

**Wichtig:** Solange ein Node noch einlernt (`capacity_ready=false`), weist der Master diesem Node **0%** zu. Der Node lehnt Setpoints sowieso ab bis sein Learning abgeschlossen ist. Im Master-UI erscheint `LEARNING X/N Turbinen stabil (Y Samples)` pro lernenden Node und in der RT-Zusammenfassungszeile `LEARNING: N Node(s) lernen noch ein`.

### Deduplizierung

Setpoints werden nur gesendet wenn sich **funktionale Felder** geändert haben (power_percent, target_rpm, enable_reactors/turbines, assignment_state, desired_node_state). Interne Bezeichner wie `assignment_reason` lösen keine neuen Pakete aus.

### Monitor-UI Tabs

| Tab | Inhalt |
|-----|--------|
| Overview | Gesamtsystem, Energie, Alerts |
| RT-Dashboard | RT-Status, RPM, Kapazität, Learning-Status |
| Energy | Matrix-Status |
| Alerts | Alarme |
| Logs | Log-Modus-Buttons |

Wenn kein externer Monitor: Fallback auf Terminal (`monitor_manager.lua`).

---

## 5. RT Node — Reaktor & Turbinen

Die RT-Node betreibt eine vollständig lokale Sicherheitsschleife, unabhängig vom MASTER. Jede Node kann beliebig viele Turbinen und Reaktoren verwalten.

### Startsequenz

```
1. Boot → 5s warten (LOG_COLLECTOR soll zuerst starten)
2. Peripherals entdecken (Reaktor + alle Turbinen)
3. CAPACITY LEARNING
4. Nach Lock: MASTER-Modus aktiv, SET_SETPOINTS werden akzeptiert
```

### Capacity Learning

**Ziel:** Maximale Energieproduktion der Anlage messen und dauerhaft cachen.

```
Lernphase:
├─ Reaktorstäbe: normaler Rod-Regulator aktiv (gleiche Regeln wie Normalbetrieb)
├─ ALLE Turbinen gleichzeitig auf 900 RPM regeln
├─ Warten bis ALLE Turbinen stabil:
│    - RPM innerhalb ±10% von Ziel-RPM
│    - Coil eingeklinkt
│    - Energie > 0 gemessen
├─ 3 aufeinanderfolgende stabile Samples → LOCK
│    (Abbruch bei einem instabilen Sample → Zähler zurück auf 0)
└─ Cache: /xreactor/config/capacity_cache.lua
           (enthält max_output und turbine_count)

Nach Lock:
├─ max_output wird nur noch aktualisiert wenn neuer Wert > 1% über bisherigem Max
└─ Cache-Invalidierung: automatisch wenn turbine_count sich ändert
```

Während des Learnings sendet der Master 0% — der Node behält `capacity_ready=false` bis der Lock abgeschlossen ist.

### Turbinen-Regelkreis — immer geschlossen

Der Flow-Regelkreis läuft für **jede Turbine, jeden Tick**, ohne Ausnahme:

```
get_turbine_target_rpm(turbine_index):
  Außerhalb MASTER-Modus:                → base_rpm für alle
  Im MASTER-Modus:
    virt_slot = (index - 1 + rotation_offset) % total
    virt_slot < full_count  → base_rpm   (Vollast)
    virt_slot == full_count → partial_rpm (Teillast, falls remainder > 1%)
    virt_slot > full_count  → 0          (austrudeln)
```

### Reaktor-Rod-Regelung

Der Rod-Regulator läuft identisch während Learning und Normalbetrieb:

```
steam_margin = verfügbarer_Dampf − gesamter_Dampfbedarf_aller_Turbinen
Positiver Margin → Stäbe reinfahren (weniger Dampf)
Negativer Margin → Stäbe rausfahren (mehr Dampf)

Deadband:         ±5000 mB
Schrittweite:     max ±5% pro Anwendung
Cooldown:         1.5s zwischen Anpassungen
Regelbereich:     rails.reactor_rods.min=80% .. max=100% Insertion

Kühlmittel-Schutz:
  Ratio ≤ 0.28 (soft): max 2 Schritte raus
  Ratio ≤ 0.22 (hard): kein Rausfahren
  Ratio ≤ 0.20 (trip): Sicherheitsabschaltung

Safety-Overrides (bypassen Rod-Caps):
  SCRAM / EMERGENCY  → 100% Insertion (sofort)

Log-Indikator:
  ReactorCtrl margin=<N> rods_current=<X> rods_target=<Y> source=AUTO_REGULATOR
```

### Rod-Konfiguration

Kanonischer Konfig-Pfad: `config.rails.reactor_rods.min` / `.max`

Veraltete Pfade (`autonom.regulator_min_rods`, `autonom.min_rods`) werden automatisch auf den neuen Pfad migriert und loggen eine Warnung.

`CONFIG.INITIAL_ROD_LEVEL = 98` — Rod-Level beim allerersten Start (Stäbe fast zu).

### Node-States

| State | Bedeutung |
|-------|-----------|
| `INIT` | Bootstrap, noch keine Peripherals |
| `AUTONOM` | Kein MASTER verbunden, lokaler Betrieb |
| `MASTER` | MASTER verbunden, Capacity gelocked |
| `LIMITED` | Teillast |
| `EMERGENCY` | SCRAM/Temperatur-Trip, Stäbe auf 100% |

### Safety-Parameter (Defaults)

| Parameter | Wert | Konfigurierbar |
|-----------|------|---------------|
| Turbinen Ziel-RPM | 900 | `config.autonom.target_rpm` |
| Coil einschalten (Vollast) | ≥ 900 RPM | `rails.coil.engage_rpm` |
| Coil ausschalten (Vollast) | < 850 RPM | `rails.coil.disengage_rpm` |
| Coil-Schwellen Teillast | proportional skaliert | automatisch |
| Overspeed-Band | Ziel + 20 RPM | `rails.coil.overspeed_band` |
| Teillast-Rotation | alle 5 Min | `ROTATE_INTERVAL` in main.lua |
| Reaktorstäbe Regelbereich | 80–100% Insertion | `rails.reactor_rods.min/.max` |
| Reaktorstäbe SCRAM | 100% | nicht konfigurierbar |
| Temperatur-Trip | 2000°C | `config.autonom.max_temp` |
| Steam Guard high | 0.82 | `rails.reactor_steam_guard.high_ratio` |
| Steam Guard critical | 0.92 | `rails.reactor_steam_guard.critical_ratio` |
| Learning: stabile Samples | 3 | hartcodiert |
| Learning: Update-Schwelle | +1% über Max | hartcodiert |

---

## 6. ENERGY Node

Überwacht Mekanism Induction Matrices und sendet Energie-Telemetrie.

### Matrix-Budget

```lua
matrix_component_time_budget_ms = 2000  -- Max Zeit pro Tick (Mekanism-API langsam)
matrix_metric_call_budget = 6           -- Max API-Calls pro Payload
```

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

Config-Dateien:
  FUEL:         /xreactor/config/fuel_routes.lua
  REPROCESSING: /xreactor/config/reproc_routes.lua
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

### Startup-Delay

Alle Nodes außer `LOG` und `MASTER` warten 5s beim Boot.

---

## 12. node_id System

### Priorität

```
1. /xreactor/config/node_id.txt  → Single Source of Truth
2. node-<computerID>             → immer stabil, nie vom Label
```

Computer-Labels sind nur menschlich lesbar. Die Netzwerk-ID ist immer `node-<ComputerID>`.

### Troubleshooting: Node offline

```sh
delete /xreactor/config/node_id.txt
reboot
```

---

## 13. Ingame Konfiguration

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

### Teillast-RPM und Effizienz

Eine Teillast-Turbine (z.B. 450 RPM) erzeugt weniger Strom pro Dampfeinheit als eine Vollast-Turbine. Die Teillast wird nur eingesetzt wenn der angeforderte Prozentsatz nicht exakt auf eine ganzzahlige Turbinen-Anzahl passt. Für feinere Leistungsregelung ohne Teillast: mehr Turbinen verwenden.

### Capacity-Learning Voraussetzungen

Learning schlägt fehl wenn:
- Nicht genug Dampf für alle Turbinen gleichzeitig vorhanden ist
- Turbinen nicht physisch angeschlossen sind
- Eine Turbine keine Energie-Readback liefert (API-Fehler)

### Log-Duplikate

Viele Turbinen × mehrere RT-Nodes → hohes Nachrichtenaufkommen. Duplikate sind nicht verlustreich — der Collector dedupliziert korrekt per `event_id`.
