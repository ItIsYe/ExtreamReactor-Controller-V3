# RT-Regel-Engine v2

**Stand: 2026-09-24 | manifest-v732 | Zweig `beta`**

Der RT-Knoten hat zwei Regel-Engines. v1 (`reactor_control.lua`,
`turbine_control.lua`, `module_lifecycle.lua`) ist der Bestand, v2
(`rt2_*.lua`) der Neubau. Welche laeuft, entscheidet **pro Knoten** ein
Eintrag in `/xreactor_config/rt.lua`:

```lua
engine = "v2",
```

Ohne den Eintrag laeuft der Knoten unveraendert auf v1. v2 soll v1
spaeter ersetzen — **noch nicht**; bis dahin ist es eine Kanarienvogel-
Umstellung auf einzelnen Knoten.

Beim Start sagt der Rechner selbst, was laeuft:

```
[RT] engine=v2 AKTIV -- 2 Reaktor(en), 30 Turbinen
```

## Warum es v2 gibt

v1 hielt den Betriebszustand an zwei Stellen gleichzeitig
(`ctx.STATE` und `node_state_machine`). Die beiden konnten
auseinanderlaufen, und genau das taten sie in der Praxis — eine
Pruefung gegen die eine Quelle ging durch, waehrend die andere etwas
anderes meinte. v2 hat **genau einen** Zustand, **eine** Stelle, die ihn
entscheidet, und alles andere liest ihn nur.

Die zweite Idee ist **Entkopplung**: Der Reaktor regelt ausschliesslich
aus seinem eigenen Dampftank — in jedem Zustand, auch unter MASTER.
MASTER verschiebt nur Turbinenziele; was das mit dem Dampf macht, merkt
der Reaktor von selbst. Damit gibt es keine "MASTER-Reaktorlogik" neben
einer "AUTONOM-Reaktorlogik", die man synchron halten muesste.

## Aufbau

| Datei | Aufgabe | rein? |
|---|---|---|
| `rt2_state.lua` | Zustandsautomat INIT/LEARNING/MASTER/AUTONOM/SAFE | ja |
| `rt2_reactor.lua` | Stabstellung aus dem Dampftank | ja |
| `rt2_turbine.lua` | Ziel-RPM, Durchfluss, Spule | ja |
| `rt2_capacity.lua` | Einlernen der Knotenleistung | ja |
| `rt2_tuning.lua` | Selbstvermessung der Anlage | ja |
| `rt2_safety.lua` | Temperatur/Kuehlmittel (nutzt `core/safety.lua`) | ja |
| `rt2_command_handler.lua` | Befehle von MASTER | ja |
| `rt2_master_link.lua` | MASTER-Verbindung, 12-s-Fenster | ja |
| `rt2_projection.lua` | Uebersetzung in v1-Vokabular fuer UI und MASTER | ja |
| `rt2_unit.lua` | EIN Reaktor: Stellrate, Profil, Sicherheitslage | Zustand |
| `rt2_orchestrator.lua` | ein Takt fuer den Knoten | Zustand |
| `rt2_adapter.lua` | Peripherie lesen und schreiben | nein |
| `rt2_engine.lua` | Fassade fuer `main.lua`, Dateien | nein |

"rein" heisst: gleiche Eingabe, gleiche Ausgabe, kein `peripheral`, kein
`ctx`, kein globaler Zustand — mit schlichten Lua-Tabellen testbar.

## Mehrere Reaktoren

Der Knoten fasst seine Anlage als **ein System** auf: eine
Turbinenflotte an einem gemeinsamen Dampfnetz, eine gelernte Kapazitaet,
eine Leistungsvorgabe. Eine Zuordnung Turbine → Reaktor gibt es bewusst
**nicht** und sie ist auch nicht noetig.

Was sich nicht teilen laesst, ist die Reaktorregelung: Jeder Reaktor hat
seinen eigenen Dampftank und regelt seine Staebe daraus. Genau das macht
sie unabhaengig, ohne Absprache — zieht die Flotte mehr, fallen alle
Taenke und alle fahren die Staebe aus; faellt einer aus, leert sich der
Tank der uebrigen schneller und sie fahren nach. Die Rueckkopplung laeuft
ueber den Dampf, nicht ueber Code.

Turbinenzahl ist nicht begrenzt (nachgemessen bis 100).

## Zustaende

| Zustand | Bedeutung | Turbinenziel |
|---|---|---|
| INIT | Discovery noch nicht vollstaendig | — |
| LEARNING | Kapazitaet wird gemessen | 900 fuer alle |
| MASTER | MASTER verbunden, dessen Vorgabe gilt | Vollast/Puffer/AUS |
| AUTONOM | kein MASTER | 900 fuer alle |
| SAFE | kein Reaktor mehr regelbar | 0 |

Der Modus wird **nie befohlen**: MASTER gegen AUTONOM ergibt sich allein
aus dem Zeitstempel der letzten MASTER-Nachricht (12 s). `SET_MODE` wird
angenommen und tut nichts.

## Sicherheit

Ein Ausloeser (Temperatur, Kuehlmittel) faehrt **nur seinen eigenen**
Reaktor ein; die Flotte laeuft auf dem Dampf der uebrigen weiter. Ein
ausgeloester Reaktor misst nicht mehr und wird nicht wieder
eingeschaltet. Erst wenn **kein** Reaktor mehr regelbar ist, geht der
Knoten auf SAFE und stellt auch die Turbinen ab.

Ein Hand-SCRAM haelt, bis ein Startbefehl
(`REQUEST_STARTUP_MODULE`/`STARTUP_STAGE`) ihn loest — eine physische
Bedingung dagegen wird jeden Takt neu bewertet und laesst sich nicht
wegquittieren.

## Einlernen

Gemessen wird der **hoechste Gesamtausstoss, der tatsaechlich floss**:
jeden Takt die Energie aller Turbinen summieren, die gerade am Ziel
(900 ± 15 RPM) und gekuppelt sind, und davon das Maximum behalten. Ein
Takt zaehlt nur, wenn mindestens **80 %** der Flotte gleichzeitig im
Zielbereich stehen. Bleibt der Hoechstwert 6 s stehen, ist die Anlage
ausgemessen.

Nicht hochgerechnet: Frueher wurde aus wenigen Turbinen auf die
Gesamtzahl geschlossen — das erfand Leistung fuer Turbinen, die in dem
Moment nichts lieferten.

Diese Zahl ist der Zweck des Ganzen: MASTER teilt seinen Leistungsbedarf
gegen sie auf (`capacity_max` im Statuspayload).

## Selbstvermessung

`rt2_tuning.lua` misst **je Reaktor**, wie schnell sein Dampftank auf
eine Stabbewegung reagiert — rein beobachtend, ohne Stoersignal. Aus der
Ausgleichsgeraden durch (Stabstellung → Fuellrate) folgen Stellintervall
und Schrittweite, beide hart geklammert. Gemessen wird einmal, das
Ergebnis wird persistiert.

## Dateien unter `/xreactor_config/`

| Datei | Inhalt |
|---|---|
| `rt.lua` | `engine = "v2"`, Sicherheitsgrenzen |
| `rt2_capacity_cache.lua` | gemessene Knotenleistung (flach — eine Flotte) |
| `rt2_reactor_tuning.lua` | Anlagenprofil je Reaktor |

## Anzeige

v2 fuehrt seinen Zustand nur in sich selbst. Alles, was ihn anzeigt,
liest v1-Feldnamen — also muss `main.lua` an **jeder** Stelle
uebersetzen, an der eine Anzeige gefuellt wird:

| Weg | Quelle | Uebersetzung in |
|---|---|---|
| Statuspayload an MASTER | `rt2_engine.status_fields()` | `build_status_payload()` |
| RT-eigener Monitor | `rt2_engine.status_fields()` | `update_monitor()` |

Die zweite Zeile fehlte und ist im ersten Livetest aufgefallen: im
Terminal lief `v2 Einlernen FERTIG: … RF/t aus 25 Turbinen`, waehrend
derselbe Knoten auf seinem Monitor gleichzeitig `! LEARNING`,
`> KAPAZITAET WIRD GELERNT`, `CAPACITY 0.0`, `SOLL 0.0` und
`MASTER % 0.0` zeigte. Beides stimmte fuer sich — die Regelung lief auf
v2, die Anzeige las v1:

- `ctx.capacity_learning` ist v1s Lernzustand; unter `engine = "v2"`
  fuellt ihn niemand mehr.
- `ctx.node_state_machine` wird unter v2 bewusst nie weitergeschaltet
  (siehe unten) und bleibt auf seinem Bootwert.
- `ctx.targets` fuellte v1s `command_handler`, den `handle_command_v2`
  ersetzt — die Leistungsvorgabe lebt jetzt im Orchestrator
  (`master_percent`).

`monitor_ui.lua` bleibt engine-agnostisch: es nimmt mit
`ctx.capacity_override` / `ctx.node_state` / `ctx.targets` entgegen, was
der Aufrufer ihm gibt, und faellt ohne diese Vorgaben auf v1 zurueck.
Abgesichert in `rt2_monitor_v2_display_test.lua` — inklusive der Pruefung,
dass `update_monitor()` die Uebersetzung auch wirklich aufruft.

## Was v2 bewusst NICHT tut

- **Kein gestaffelter Start.** Alle Turbinen fahren gleichzeitig auf Ziel.
- **Keine Zuordnung Turbine → Reaktor** (siehe oben).
- **Kein Ansteuern von v1s `node_state_machine`.** Deren
  Eintrittshandler wuerden echte v1-Regelarbeit ausloesen, darunter einen
  SCRAM. v2 meldet den uebersetzten Zustand, statt ihn zu schalten — zwei
  Regler auf derselben Hardware sind genau der Fehler, den der Umbau
  beseitigen sollte.

## Tests

| Datei | prueft |
|---|---|
| `rt2_lifecycle_test.lua` | PC-Start → Einlernen → MASTER/AUTONOM → SAFE → Neustart (13 Abschnitte) |
| `rt2_twin_reactor_integration_test.lua` | zwei Reaktoren, 30 Turbinen, echter Adapterstapel |
| `rt2_engine_integration_test.lua` | 25 Turbinen, echter Adapterstapel |
| `rt2_two_reactor_test.lua` | Unabhaengigkeit der Reaktoren |
| `rt2_regulation_behaviour_test.lua` | Einzelregelung je Turbine |
| `rt2_capacity_to_master_test.lua` | Kette gemessener Wert → Statusfelder → MASTER-Aufteilung |
| `rt2_fuel_chain_test.lua` | Reaktor-Fuellstand bis zur FUEL-Node (beide Wege) |
| `rt2_tuning_test.lua` | Selbstvermessung gegen eine bekannte Anlage |
| `rt2_monitor_v2_display_test.lua` | RT-Schirm zeigt v2s Zustand, nicht v1s leeren |
| plus Modultests je `rt2_*`-Datei | |

## Offen

- **Livetest laeuft.** Erster Durchlauf auf node-101 (25 Turbinen,
  1 Reaktor): Einlernen ging durch und meldete einen gemessenen Wert.
  Befund daraus war die fehlende Uebersetzung fuer den RT-eigenen
  Monitor (siehe „Anzeige"), nicht die Regelung selbst.
- **Groessenordnung des gemessenen Werts pruefen.** Der Livetest mass
  834 054 315 RF/t aus 25 Turbinen, also rund 33 M RF/t je Turbine.
  Die Zahl ist in sich stimmig (dieselbe Quelle
  `getEnergyProducedLastTick` speist auch die IST-Anzeige, und die lag
  mit 631 M darunter — ein reiner Zaehlerstand koennte das nicht), aber
  ungeprueft gegen das, was die ENERGY-Node am Induktionsmatrix-Eingang
  sieht. Stimmt die Skala nicht, stimmt auch MASTERs ganze Aufteilung
  nicht, denn sie rechnet gegen genau diesen Wert.
- Der Umstieg von v1 auf v2 als Standard ist **nicht** beschlossen.
