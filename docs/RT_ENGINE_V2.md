# RT-Regel-Engine v2

**Stand: 2026-09-29 | manifest-v779 | Zweig `beta`**

Der RT-Knoten hat **genau eine** Regel-Engine (`rt2_*.lua`). Der
Vorgaenger v1 (`reactor_control.lua`, `turbine_control.lua`,
`module_lifecycle.lua`, `state_handlers.lua`, `command_handler.lua`,
`capacity_learning.lua` …) ist mit v770 vollstaendig entfernt — es gibt
keine Umschaltung und keinen Eintrag `engine =` mehr. Die RT-Rolle ist
dadurch von 782 KB auf 584 KB geschrumpft und passt wieder auf einen
Standardrechner.

Beim Start sagt der Rechner selbst, was er gefunden hat:

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
| `rt2_state.lua` | Zustandsautomat INIT/MASTER/AUTONOM/SAFE | ja |
| `rt2_reactor.lua` | Stabstellung aus dem Dampftank | ja |
| `rt2_turbine.lua` | Ziel-RPM, Durchfluss, Spule | ja |
| `rt2_safety.lua` | Temperatur/Kuehlmittel (nutzt `core/safety.lua`) | ja |
| `rt2_command_handler.lua` | Befehle von MASTER | ja |
| `rt2_master_link.lua` | MASTER-Verbindung, 12-s-Fenster | ja |
| `rt2_projection.lua` | Uebersetzung in v1-Vokabular fuer UI und MASTER | ja |
| `rt2_unit.lua` | EIN Reaktor: Stellrate, letzter Messwert, Sicherheitslage | Zustand |
| `rt2_orchestrator.lua` | ein Takt fuer den Knoten | Zustand |
| `rt2_adapter.lua` | Peripherie lesen und schreiben | nein |
| `rt2_engine.lua` | Fassade fuer `main.lua` | nein |

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

Die Einheitenliste wird **je Takt** an die Reaktoren angeglichen, die der
Takt mitbringt, und nach **Namen** gepaart. Beides musste sein:

- Die Discovery laeuft nach `init()` weiter und bindet den zweiten
  Reaktor oft erst spaeter. Die Liste entstand frueher einmalig beim
  Start — jeder Takt brachte dann zwar zwei Messwerte, es gab aber nur
  eine Einheit, und der zweite Reaktor blieb ungeregelt stehen (im
  Betrieb gemeldet, 2026-09-25).
- Die Discovery sortiert nicht stabil. Ueber die Position zu paaren
  hiesse, einem Reaktor die Staebe des anderen zu stellen — schlimmer,
  als ihn gar nicht zu regeln.

Ein Reaktor behaelt dabei seinen Messzustand (Stellrate, Anlagenprofil,
Sicherheitslage); einer, der erst spaeter dazukommt, bekommt sein
gemessenes Profil aus `rt2_reactor_tuning.lua`. Festgehalten in
`rt2_late_reactor_discovery_test.lua` — bewusst auf dem Weg der Anlage
(erst einer bekannt, dann zwei), denn die bestehenden Zwei-Reaktor-Tests
uebergeben beide schon an `orchestrator.new()` und sind dem Fehler
deshalb entgangen.

## Zustaende

| Zustand | Bedeutung | Turbinenziel |
|---|---|---|
| INIT | Discovery noch nicht vollstaendig | — |
| MASTER | MASTER verbunden, dessen Vorgabe gilt | 900 oder 0 |
| AUTONOM | kein MASTER | 900 fuer alle |
| SAFE | kein Reaktor mehr regelbar | 0 |

Der Knoten LERNT weiterhin ein (siehe unten) — aber nicht mehr in einem
eigenen ZUSTAND. Bis v769 stand hier ein `LEARNING`, das der Knoten erst
verlassen durfte, wenn ein gestaffelter Suchlauf fertig war; solange hoerte
er nicht auf MASTER, und an mehreren Stellen kam er dort nicht mehr heraus.
Der Zustand ist weg und bleibt weg: sobald Hardware da ist, arbeitet der
Knoten — Kommandos, Status und Sicherheitsfaelle laufen waehrend des
Einlernens ganz normal. Uebersteuert wird einzig die Leistungsvorgabe.

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

## Leistungsvorgabe von MASTER

Die Vorgabe in Prozent bestimmt, **wieviele** Turbinen laufen — nicht,
wie schnell sie drehen. 60 % von 50 Turbinen heisst 30 Turbinen auf
900 RPM, 20 stehen. Welche Plaetze stehen, wandert alle 5 Minuten, damit
keine Turbine dauerhaft kalt bleibt.

Das ist bewusst grob. Eine Turbine ausserhalb ihres Auslegungspunkts
liefert unverhaeltnismaessig wenig, deshalb ist „weniger Turbinen, alle
auf 900" die bessere Aufteilung als „alle Turbinen, alle zu langsam". Den
frueheren Teillast-Platz mit krummer Zieldrehzahl gibt es nicht mehr.

### Was MASTER dafuer braucht

MASTER teilt seinen Leistungsbedarf gegen `capacity_max` auf. Diese Zahl
muss beschreiben, was die Flotte liefert, wenn **alle** Turbinen laufen —
denn MASTER rechnet den Prozentsatz als Anteil der LEISTUNG
(`assigned_power = capacity * pct / 100`, `master/rt_sync.lua`), waehrend
der Knoten ihn als Anteil der TURBINEN umsetzt. Beides deckt sich nur bei
einer Zahl fuer die volle Flotte.

## Einlernen

Verfahren wie vor v769 (damals `rt2_capacity.lua`), Betreibervorgabe:

> „im learning modus muessen 80% der turbinen im ziel rpm bereich sein
> +-15 rpm. das heisst die turbinen muessen auch unabhaengig vom master
> waehrend des lernens — aber auch nur waehrend des lernens — auf 900 rpm
> gebracht werden. sobald das abgeschlossen ist geht dan wieder ganz
> normale regelung."

Gemessen wird der **hoechste Gesamtausstoss, den die Anlage jemals
nachweislich GLEICHZEITIG geliefert hat**:

| | |
|---|---|
| Zielband | 900 ± 15 RPM (`LEARN_TOLERANCE_RPM`) |
| Mindestanteil | 80 % der Flotte, gleichzeitig (`LEARN_MIN_FRACTION`) |
| Abschluss | Hoechstwert steigt 6 s nicht mehr (`LEARN_STABLE_MS`) |
| Reserve | gemeldet werden 95 % davon (`LEARN_SAFETY_MARGIN`) |
| Notbremse | nach 3 min endet es in jedem Fall (`LEARN_TIMEOUT_MS`) |

Ein Takt zaehlt nur, wenn genug Turbinen gleichzeitig im Band stehen,
gekuppelt sind und wirklich liefern — eine Summe aus drei zufaellig
laufenden Turbinen beschreibt die Anlage nicht. Von den tauglichen Takten
gilt der **Hoechstwert**, nicht der erste: damit entscheidet nicht ein
einzelner Augenblick, und ein Takt mitten im Hochlauf friert nichts ein.

**Waehrend des Einlernens faehrt die ganze Flotte auf Zieldrehzahl und die
MASTER-Vorgabe ist uebersteuert.** Nur so entsteht ein Wert, der die ganze
Anlage beschreibt — und nur so kommt der Knoten ueberhaupt aus dem Stand:
MASTER teilt gegen `capacity_max` auf, das ist beim Start 0, also kaeme
eine Vorgabe von 0 % zurueck, also liefe keine Turbine, also floesse
nichts. Danach gilt MASTERs Prozentsatz wieder unveraendert.

Eine geaenderte Turbinen-ANZAHL ist ein Umbau und laesst neu einlernen —
aber erst, wenn sie 3 s anhaelt (`TOPOLOGY_DEBOUNCE_MS`); ein Peripheral,
das einen Takt lang nicht antwortet, sieht sonst aus wie eine abgebaute
Turbine. Gar keine Turbinen gelesen ist dagegen **kein** Umbau, sondern
ein Discovery-Aussetzer: melden, nichts anfassen.

Mitgezaehlt wird ausserdem die **Saettigung**: eine Turbine, die vollen
Durchfluss faehrt und trotzdem zu langsam ist, hat keine Reglerreserve
mehr — entweder fehlt Dampf, oder die Spulenlast ist zu hoch. Das ist
reine Diagnose, aber es macht ein unsichtbares Haengen zu einem lesbaren
Befund im Log.

### Was NICHT zurueckgekommen ist

Der gestaffelte Suchlauf (v754–v757), der Turbinen stufenweise freigab und
daraus eine „tragbare Anzahl" ableitete. Er hat im Feld 49 von 50 Turbinen
abgestellt und war der Grund, warum das Einlernen haengenblieb. Ohne ihn
findet der Knoten keine tragbare Teilmenge mehr — deshalb die Notbremse
oben: bringt eine dampfarme Anlage nie 80 % ins Band, gilt nach 3 min der
hoechste geflossene Ausstoss, und das Log sagt deutlich, dass die Zahl zu
klein ist.

### Die Kette bis MASTER

`status_fields()` → `build_status_payload()` → `message_handlers.lua` →
`ui_controller.lua`. Sie laeuft ueber reine Feldnamen in vier Dateien;
bricht sie in der Mitte, faellt nichts um und die Anzeige zeigt still eine
Null. Genau so lagen `capacity_sustainable_turbines` und
`capacity_required_turbines` lange tot. Abgesichert in
`capacity_payload_chain_test.py`.

## Das Regelgesetz des Durchflusses

Es gibt **genau eines**: Abweichung zwischen Ist- und Solldrehzahl →
Durchfluss-Schritt.

```
1. Keine Drehzahlmessung   -> Dampf aus.   NO_RPM_READING
2. Ziel 0 (Turbine steht)  -> Dampf aus.   TARGET_ZERO
3. Echte Ueberdrehzahl     -> Dampf aus.   OVERSPEED
4. Nah genug am Ziel       -> nichts tun.  SETTLED
5. Stellintervall nicht um -> nichts tun.  SETTLING
6. sonst: Schritt proportional zur Abweichung, gedeckelt auf TRIM_STEP.
                                           TRIM_UP / TRIM_DOWN
```

1.–3. sind Schutz, nicht Regelung: sie greifen im selben Takt und werden
immer geschrieben, auch wenn der Rueckmesswert behauptet, es staende
schon so an. Eine Bremsung darf nicht an einer Ersparnis scheitern.

**Ruhezone** (`SETTLE_BAND_RPM`, 4 RPM): nah genug am Ziel wird gar nicht
gestellt. Ohne sie bleibt ein endloses +1/−1 uebrig, weil die
kleinstmoegliche Verstellung (1 mB/t) groesser ist als die verbleibende
Abweichung.

**Stellintervall** (`MIN_ADJUST_INTERVAL_MS`, 600 ms): der Rotor haengt
der Vorgabe um Sekunden hinterher. Ohne diese Sperre stapelt der Regler
Schritte auf eine Wirkung, die noch gar nicht eingetreten ist.

**Verstaerkung**: genau am Rand des Zielbands kommt ein voller
`TRIM_STEP` heraus, naeher am Ziel entsprechend weniger. Damit gibt es
keine Kante zwischen „weit weg" und „fast da" — und genau diese Kante war
das alte Sprungverhalten.

### Was hier frueher stand

Bis v768 lagen an dieser Stelle **vier Verfahren nebeneinander**: eine
Rampe mit eigenem Intervall, eine Feintrimmung innerhalb des Bandes, ein
Streckenmodell aus je Turbine gelernten Kennlinien
(`rt2_turbine_model.lua`) und eine Vorausschau auf die
Rotorbeschleunigung. Sie loesten sich gegenseitig ab, und welches gerade
griff, war von aussen nicht zu sehen.

Die Feldaufzeichnung vom 27.09. zeigte 26 von 40 Turbinen oberhalb des
Zielbands mit Durchfluss 0 im Auslauf, waehrend **keine einzige
Kennlinie** in Gebrauch war. Der Betreiber hat mehrfach bestaetigt, dass
es nicht an der Dampfversorgung lag. Alle vier sind durch das eine Gesetz
oben ersetzt.

### Die Spule und die Ruhezone muessen sich ueberlappen

Ein Fehler, der beim Umbau aufgefallen ist und auf beide Seiten passt:
die Ruhezone des Reglers liegt bei 900 ± 4 RPM, die Kupplungsschwelle der
Spule lag **genau auf 900**. Eine Turbine, die bei 897 einschwang, war
fuer den Regler angekommen und fuer die Spule noch darunter — sie
kuppelte nie ein, und eine ungekuppelte Turbine liefert nichts.
Dauerhaft, denn der Regler hatte keinen Grund mehr, etwas zu aendern.
Ohne Last beschleunigt der Rotor sogar, und der Regler nimmt Dampf weg,
um die 900 zu halten: die Anlage sieht in jeder Anzeige gesund aus und
produziert nichts. Im Zwillingstest blieb so die ganze Flotte bei
897 RPM stehen und meldete 0 RF/t.

Die Spule kuppelt jetzt auch dann, wenn der Regler die Turbine als
angekommen ansieht. Festgehalten in
`rt2_settled_turbine_couples_test.lua`.

Ein Nebeneffekt: eine eingeschwungene Turbine wird gar nicht mehr
beschrieben (`flow_decision.unchanged`), was je Takt einen
Peripherieaufruf pro Turbine spart.

**Diese Ersparnis hat zwei Bedingungen, und beide fehlten im ersten
Anlauf.** Im Livetest auf node-101 standen danach 25 Turbinen bei
967–1256 RPM mit vollem Durchfluss, geloester Spule und ohne jede
Reaktion — der Patch wurde deshalb zurueckgenommen (v737) und mit dem
Fix erneut aufgesetzt:

1. Es muss ein **echter Rueckmesswert** vorliegen.
   `adapters/turbine.lua`'s `read_number()` liefert bei einem
   fehlgeschlagenen Peripherieaufruf den String `"n/a"`;
   `rt2_adapter.read_turbine()` machte daraus eine `0`. „Unbekannt"
   wurde damit zu „steht auf 0" — und das entsprach zufaellig genau
   dem, was der Regler bei fehlender Drehzahl setzen wollte. Die
   Vorgabe galt als erledigt und ging nie raus, waehrend im Mod weiter
   2000 anstanden. `current_flow` ist jetzt `nil`, wenn es unbekannt
   ist, und `nil` unterdrueckt nie ein Schreiben.
2. Es darf keine **Schutzentscheidung** sein. `NO_RPM_READING`,
   `OVERSPEED` und `TARGET_ZERO` werden immer geschrieben, auch wenn der
   Rueckmesswert behauptet, es staende schon so an. Eine Bremsung darf
   nicht an einer Ersparnis scheitern.

Warum das so lange unentdeckt blieb: `monitor_ui.build_turbine_status()`
hat einen **zweiten Leseweg** (`peripheral.wrap` plus
zwischengespeicherte Faehigkeiten), den `adapters/turbine.inspect()`
nicht benutzt. Die Oberflaeche kam an die Werte, die Regelkette nicht —
auf dem Schirm sah alles normal aus.

Festgehalten in `rt2_unreadable_turbine_write_test.lua`.

**Und warum die Messwerte ueberhaupt unlesbar waren** (Ursache, eine
Ebene tiefer): CC:Tweaked wirft bei einer unbekannten Methode einen
Lua-Fehler — `PeripheralWrapper.call()` in `PeripheralAPI.java`:
`if (method == null) throw new LuaException("No such method " + methodName);`
`utils.safe_peripheral_call()` faengt den ab, `read_number()` macht
daraus `"n/a"`, also einen nicht lesbaren Messwert.

`adapters/turbine.lua`'s `inspect()` holte die Methodenliste bei **jedem
Aufruf** neu (25 Turbinen, mehrmals pro Sekunde) und waehlte daraus den
Namen fuer die Drehzahl:

```lua
read_number(name, has_method(method_set, "getRotorSpeed") and "getRotorSpeed" or "getRotorRPM")
```

Schlug `utils.safe_get_methods()` einmal fehl — ein Rennen gegen ein
kurz nicht erreichbares Peripheral genuegt —, war die Liste leer und der
Aufruf ging an `getRotorRPM`. Die gibt es bei Extreme Reactors 2
(MC 1.21.1) nicht; dort heisst sie `getRotorSpeed`. Der Ausweichweg war
damit ein garantierter Fehlschlag statt eines Ausweichwegs.

`adapters/reactor.lua` hatte das nie: dort ist **jeder** Aufruf durch
`has_method()` gedeckt. Die Turbine haelt es jetzt genauso, und merkt
sich die Faehigkeiten ausserdem je Peripherie:

- Ein fehlgeschlagener Versuch behaelt die zuletzt bekannte Liste,
  statt auf „leer" zusammenzufallen.
- Ohne bekannte Liste wird **nichts geraten** — der Messwert gilt als
  unbekannt, und die Regelung faehrt auf die sichere Seite.
- Nebenbei entfaellt je Turbine und Takt ein Peripherieaufruf.

Festgehalten in `turbine_adapter_capability_probe_test.lua`.

## Dateien unter `/xreactor_config/`

| Datei | Inhalt |
|---|---|
| `rt.lua` | Peripherienamen, Sicherheitsgrenzen — **legt der Installer an** |

Mehr legt der Knoten nicht ab. Bis v768 schrieb er drei weitere Dateien
(`rt2_capacity_cache.lua`, `rt2_reactor_tuning.lua`,
`rt2_turbine_model.lua`) mit gelernter Kapazitaet, gemessenem
Anlagenprofil je Reaktor und Kennlinie je Turbine. Die letzten beiden
veraenderten die Regelung von Lauf zu Lauf — ein Neustart war damit nie
wirklich derselbe Zustand; es gelten jetzt die festen Werte aus
`rt2_reactor.lua` und `rt2_turbine.lua`.

**Der Kapazitaets-Cache ist damit ebenfalls weg**: die Anlage wird nach
jedem Neustart neu eingelernt. Das dauert, solange die Flotte braucht, um
80 % ins Zielband zu bringen — und es hat den Vorteil, dass kein
veralteter Wert aus einer Datei zurueckkommen kann, nachdem sich an der
Anlage etwas geaendert hat. Soll der Wert einen Neustart ueberdauern, ist
das eine eigene Entscheidung und eine eigene Datei.

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

- `ctx.capacity_learning` war v1s Lernzustand; den fuellte niemand mehr.
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
| `rt2_lifecycle_test.lua` | PC-Start → MASTER/AUTONOM → SAFE → Neustart (13 Abschnitte) |
| `rt2_twin_reactor_integration_test.lua` | zwei Reaktoren, 30 Turbinen, echter Adapterstapel |
| `rt2_engine_integration_test.lua` | 25 Turbinen, echter Adapterstapel |
| `rt2_two_reactor_test.lua` | Unabhaengigkeit der Reaktoren |
| `rt2_regulation_behaviour_test.lua` | Einzelregelung je Turbine |
| `rt2_settled_turbine_couples_test.lua` | Ruhezone und Kupplungsschwelle ueberlappen sich |
| `rt2_unreadable_flow_commands_zero_test.lua` | unbekannter Durchfluss wird nie als 0 geschrieben |
| `rt2_fuel_chain_test.lua` | Reaktor-Fuellstand bis zur FUEL-Node (beide Wege) |
| `rt2_monitor_v2_display_test.lua` | RT-Schirm zeigt den wirklichen Zustand |
| `rt_boot_smoke_test.lua` | Kaltstart der ganzen Rolle auf einer simulierten Anlage |
| `rt2_learning_test.lua` | Einlernen: 80 %, Zielband, Hoechstwert, Notbremse, Umbau |
| `rt2_clock_backwards_no_regulator_lock_test.lua` | eine zurueckspringende Uhr sperrt weder Durchfluss- noch Stabregelung aus |
| `rt2_turbine_flow_decoupled_from_tank_test.lua` | der Dampftank regelt den Reaktor, nicht die Turbinen |
| `capacity_payload_chain_test.py` | die Kapazitaets-Kette Node → Payload → MASTER → UI ist durchgehend |
| plus Modultests je `rt2_*`-Datei (`rt2_turbine`, `rt2_reactor`, `rt2_state_machine`, `rt2_orchestrator`, `rt2_engine`, `rt2_adapter`, `rt2_safety`, `rt2_projection`, `rt2_master_link`, `rt2_command_handler`) | |

## Stand im Betrieb

**Bestaetigt (Betreiber, 2026-09-25): ein Reaktor mit 25 Turbinen laeuft
im Spiel einwandfrei.** Der Regler bleibt ruhig und haelt die Drehzahl.

Das galt fuer die Fassung v740 — also mit allen drei Korrekturen, die
der Livetest erzwungen hat:

| | |
|---|---|
| v733 | RT-Monitor zeigt v2-Daten statt v1 |
| v738 | unbekannt ≠ 0; Schutzentscheidungen werden immer geschrieben |
| v739 | keine geratenen Peripherie-Methodennamen mehr |

Ebenfalls bestaetigt: **Lastwechsel** und dass der gemeldete Ausstoss zu
dem passt, was an der ENERGY-Node ankommt — die Groessenordnung des
gemessenen RF/t-Werts ist damit geklaert.

**Zwei Reaktoren liefen zunaechst nicht**: einer wurde geregelt, der
andere nicht, waehrend die Turbinen sauber liefen. Ursache und Behebung
siehe „Mehrere Reaktoren"; behoben in v742, im Spiel noch nicht
nachgeprueft.

Nicht bestaetigt bleibt **mehr als 25 Turbinen** — nur gegen Tests belegt
(nachgemessen bis 100).

**Bestaetigt (Betreiber, 2026-09-28, Fassung v770): der vereinfachte
Regler laeuft, auch im Doppelsetup, ohne erkennbare Probleme.** Das ist
der erste Stand ohne Lernphase, ohne Kennlinien und ohne v1 — er ist als
`stable-beta-v770` markiert.

## Offen

- ~~**Zwei Reaktoren im Spiel nachpruefen.**~~ Erledigt: der Betreiber
  hat das Doppelsetup mit v770 im Spiel gefahren, ohne erkennbare
  Probleme.
- ~~**Groessenordnung des gemessenen Werts pruefen.**~~ Erledigt: der
  Betreiber hat bestaetigt, dass der gemeldete Ausstoss zu dem passt, was
  an der ENERGY-Node ankommt. Zum Nachlesen, was da gemessen wurde: der
  Livetest mass
  834 054 315 RF/t aus 25 Turbinen, also rund 33 M RF/t je Turbine.
  Die Zahl ist in sich stimmig (dieselbe Quelle
  `getEnergyProducedLastTick` speist auch die IST-Anzeige, und die lag
  mit 631 M darunter — ein reiner Zaehlerstand koennte das nicht), aber
  ungeprueft gegen das, was die ENERGY-Node am Induktionsmatrix-Eingang
  sieht. Stimmt die Skala nicht, stimmt auch MASTERs ganze Aufteilung
  nicht, denn sie rechnet gegen genau diesen Wert.
- Der Umstieg von v1 auf v2 als Standard ist **nicht** beschlossen.
