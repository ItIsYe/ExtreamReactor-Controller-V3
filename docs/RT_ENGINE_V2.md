# RT-Regel-Engine v2

**Stand: 2026-09-30 | manifest-v793 | Zweig `beta`**

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
| Abbruch auf Zeit | **gibt es nicht** — es wird gewartet, bis die geforderten Turbinen da sind |
| Danach | wird **nur nach oben** nachgefuehrt (siehe unten) |

Eine Turbine zaehlt in einem Takt nur, wenn **alle vier** Bedingungen
gleichzeitig gelten (`measure()`):

| | |
|---|---|
| Drehzahl | lesbar (nicht `nil`) |
| Spule | eingehaengt |
| Drehzahl im Band | `abs(rpm − 900) <= 15` |
| **Ausstoss** | **`energy > 0`** — sie muss in diesem Takt Leistung melden |

Die vierte ist die unscheinbarste und hat im Betrieb am meisten gekostet:
war der Ausstoss nicht lesbar, lieferte `adapters/turbine.lua` still eine
0, keine Turbine erreichte je das Band, und das Einlernen wartete endlos —
waehrend die Anzeige nur „0 von 50 im Zielband" sagte, als laege es an der
Drehzahl. Seit v793 hat der Ausstoss einen Ausweichweg
(`getEnergyStats().energyProducedLastTick`, derselbe Feldname, den
`adapters/reactor.lua` schon immer liest), bleibt bei Unlesbarkeit
**unbekannt statt 0**, und die Node sagt es laut auf dem Rechner.

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

### Nachfuehrung nach dem Einlernen

Ist die Anlage ausgemessen, bleibt der Wert stehen — **ausser die Flotte
liefert mehr**. Dann wird er angehoben, nie gesenkt.

Es gelten dieselben Bedingungen wie beim Einlernen: der Takt zaehlt nur bei
mindestens 80 % der Turbinen gleichzeitig im Band, gekuppelt und liefernd.
Ein einzelner guenstiger Augenblick kann den Wert also genauso wenig
verfaelschen wie waehrend des Einlernens, und ein schwacher Takt kann ihn
nicht kaputtmachen.

Vorher war der Wert mit dem Ende des Einlernens endgueltig eingefroren.
Das war einseitig gedacht: der Schutz galt nur gegen ein Absinken. Wurde
beim Einlernen knapp die 80-%-Schwelle erreicht, merkte sich MASTER
dauerhaft eine zu kleine Zahl und teilte die Anlage zu klein auf — auch
wenn spaeter die ganze Flotte im Zielband stand.

Eine Anhebung steht im Log als `v2 Leistung nach oben korrigiert: alt ->
neu RF/t`, damit sie nicht mit der Erstmessung verwechselt wird.

Neu **gemessen** (also von vorn) wird weiterhin nur bei einer Aenderung der
Turbinen-Anzahl.

### Was NICHT zurueckgekommen ist

Der gestaffelte Suchlauf (v754–v757), der Turbinen stufenweise freigab und
daraus eine „tragbare Anzahl" ableitete. Er hat im Feld 49 von 50 Turbinen
abgestellt und war der Grund, warum das Einlernen haengenblieb. Ohne ihn
findet der Knoten keine tragbare Teilmenge mehr. Bringt eine dampfarme
Anlage die 80 % nie ins Band, **wartet das Einlernen** — es endet nicht auf
Verdacht mit einer geschaetzten Zahl.

Eine solche Notbremse gab es kurzzeitig (bis v789, `LEARN_TIMEOUT_MS`,
3 min). Sie ist auf Betreibervorgabe entfallen, und das aus gutem Grund:
der eingelernte Wert ist die Grundlage, auf der MASTER die ganze Anlage
aufteilt. Eine zu kleine Zahl dort ist keine Ungenauigkeit, sondern eine
dauerhaft zu klein ausgelegte Anlage — und sie sieht von aussen genauso aus
wie eine richtige. Sichtbar warten ist besser als still falsch rechnen: der
Knoten meldet in jedem Takt, wie viele Turbinen noch fehlen.

Endlos haengen kann es dadurch nicht: sobald die geforderten Turbinen
EINMAL gemeinsam im Zielband waren, laeuft die Messung ueber
`LEARN_STABLE_MS` in ihr Ergebnis — auch wenn die Flotte danach wieder
darunter faellt.

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
4. Am Ziel UND ruhig       -> nichts tun.  SETTLED
5. Stellintervall nicht um -> nichts tun.  SETTLING
6. Vorhersage trifft       -> nichts tun.  ON_PREDICTED_TARGET
7. Nah am Ziel             -> feiner Schritt.  FINE_UP / FINE_DOWN
8. sonst: Schritt proportional zur Abweichung.  TRIM_UP / TRIM_DOWN
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
Schritte auf eine Wirkung, die noch gar nicht eingetreten ist. Sie
entfaellt, sobald eine Aenderungsrate vorliegt — der Vorhalt loest
dasselbe Problem auf dem richtigen Weg (siehe unten) — und ebenso beim
Bremsen oberhalb des Bands.

### Vorhalt — schnell reagieren, ohne zu ueberschwingen

Betreibervorgabe: „fast instant reagieren, aber trotzdem nicht
ueberschwingen." Mit einem Regler, der nur die IST-Drehzahl sieht, ist das
nicht zu haben: schnell heisst grosse Verstaerkung, und grosse
Verstaerkung heisst Ueberschwingen.

Geregelt wird deshalb auf die Drehzahl, die in `LOOKAHEAD_S` (1 s) anliegt,
wenn es so weitergeht — aus der Aenderungsrate zweier aufeinanderfolgender
Messpunkte:

```
Vorhersage = Drehzahl + Rate * LOOKAHEAD_S
```

Eine Turbine bei 800 mit +250 U/min/s ist damit nicht „100 zu langsam",
sondern „150 zu schnell": der Regler nimmt zurueck, **waehrend** sie noch
steigt. Weit weg darf er dafuer viel entschiedener zupacken
(`MAX_TRIM_STEP_UP`/`MAX_TRIM_STEP_DOWN`, je 400), weil ihn die Rate
rechtzeitig wieder einbremst.

Das ist **kein Lernen**: nichts wird gespeichert, nichts ueber Takte
hinaus gemittelt, keine Kennlinie gebildet. Zwei Messwerte aus zwei Takten.

Abgesichert an drei Stellen:

| | |
|---|---|
| `MAX_PREDICT_RPM` (300) | soweit darf die Vorhersage die Lage hoechstens verschieben |
| `MAX_RATE_AGE_MS` (3 s) | aelter, und die Rate gilt als unbekannt (auch bei Uhrsprung) |
| `SETTLE_RATE_RPM_PER_S` (12) | die Ruhezone verlangt kleine Abweichung **und** kleine Rate |

Ohne Rate faellt alles auf das alte Verhalten zurueck, **einschliesslich**
des vorsichtigen `TRIM_STEP` nach oben: der grosse Schritt ist nur
vertretbar, weil die Vorhersage einbremst — faellt sie weg, faellt er weg.

`LOOKAHEAD_S` ist gemessen, nicht geraten. Anfahrt aus dem Stand auf 900
gegen drei Rotortraegheiten:

| Vorhalt | Spitze (1,4 s / 5 s / 12,5 s) | im Band nach |
|---|---|---|
| aus | 1049 / 999 / 969 | 10,0 / 27,0 / 58,5 s |
| **1,0 s** | **899 / 962 / 954** | **7,0 / 14,5 / 37,0 s** |
| 2,0 s | 898 / 918 / 938 | 12,0 / 13,0 / 28,0 s |

2 s ist bei traegen Rotoren besser, beim schnellen wieder schlechter — das
Aufschwingen, wenn der Vorhalt die Zeitkonstante der Strecke ueberholt.

### Feinzone — nah am Ziel feiner stellen

Innerhalb von `FINE_BAND_RPM` (15 RPM, dasselbe Zielband wie beim
Einlernen) zaehlt die Aenderungsrate erst ab `FINE_RATE_GATE_RPM_PER_S`
(40 U/min/s), und der Schritt ist auf `FINE_TRIM_STEP` (10) gedeckelt.

Grund: was nah am Ziel grob macht, ist nicht die Verstaerkung — der Schritt
ist dort ohnehin klein. Es ist der Vorhalt. Die Rate entsteht aus zwei
Messwerten, und die Drehzahlmessung rauscht; aus ±6 U/min Rauschen je
halbem Takt werden 24 U/min/s Scheinrate, bei 1 s Vorhalt also 24 U/min
Scheinabweichung. Weit weg geht das im echten Fehler unter — nah am Ziel
**ist** es der ganze Fehler, und der Regler stellt Rauschen nach.

Gemessen (Rotor lag=0,04, Rauschen ±6 U/min, Spanne des Durchflusses in
der Ruhelage ueber 100 Takte):

| | Spanne | im Band nach |
|---|---|---|
| ohne Feinzone | 77 | 36,5 s |
| nur Schrittdeckel 6 | 45 | 47,0 s |
| **nur kurzer Vorhalt** | **42** | **38,0 s** |
| beides | 41 | 45,5 s |

Der kurze Vorhalt bringt fast die ganze Ruhe und kostet anderthalb
Sekunden; der Schrittdeckel kostet zehn und bringt kaum mehr.

Zweiter Durchgang („bei fine noch feiner"), dieselbe Messung plus die
mittlere **Schrittweite** je Verstellung — genau die macht „feiner" aus:

| Feinzone | Spanne | Schritt | im Band nach |
|---|---|---|---|
| Vorhalt 0,25 s, Deckel 20 | 49 | 6,4 | 38,0 s |
| **Vorhalt aus, Deckel 10** | **41** | **4,4** | **38,0 s** |
| Vorhalt aus, Deckel 6 | 37 | 4,2 | 46,5 s |
| Vorhalt aus, Deckel 3 | 24 | 2,9 | 59,0 s |

Auch die verbliebenen 0,25 s Vorhalt sind in der Feinzone fast nur noch
Rauschen. Ganz abzuschalten macht den Schritt um ein Drittel kleiner und
kostet nichts; darunter wird es teuer.

**Aber nicht bedingungslos abschalten.** Das nimmt einen Fall mit, fuer den
der Vorhalt gerade gebraucht wird: eine Turbine, die mit +100 U/min/s mitten
durch das Ziel beschleunigt, wird dann nur noch gehalten statt gebremst —
sie faellt erst 15 Umdrehungen spaeter aus der Feinzone. Deshalb ein **Tor**
statt eines Schalters: unter `FINE_RATE_GATE_RPM_PER_S` ist die Rate
Rauschen und wird vollstaendig ignoriert, darueber gilt der volle Vorhalt.
Der Wert liegt ueber dem, was Messrauschen erzeugen kann (±6 U/min auf einen
halben Takt sind bis zu 24 U/min/s); eine echte Durchfahrt liegt um ein
Vielfaches darueber.

Der Deckel bleibt als Grenze stehen — er greift im Normalfall nicht und
faengt nur einen Rauschausreisser ab.

Die Feinzone haengt am **gemessenen** Abstand, nicht am vorhergesagten:
„nah am Zielbereich" ist eine Aussage darueber, wo die Turbine steht. Eine,
die noch 200 entfernt ist und schnell darauf zulaeuft, gehoert nicht
hinein — die soll weiter kraeftig zurueckgenommen werden duerfen.

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

### Die Kalibrierung gewinnt gegen die MASTER-Vorgabe

Waehrend des Einlernens faehrt die Flotte auf 100 %, auch wenn MASTER
weniger vorgibt -- einschliesslich eines ausdruecklichen 0-%-Holds.

Das ist eine **Betreiberentscheidung und bleibt so**. Ohne diesen Vorrang
gaebe es einen Start-Deadlock: MASTER teilt seinen Bedarf gegen
`capacity_max` auf, das beim Start 0 ist, also kaeme 0 % zurueck, also
liefe keine Turbine, also floesse nichts, also bliebe `capacity_max` 0.

Die Folge muss man trotzdem kennen: **eine als 0 % uebermittelte Pause ist
waehrend des Einlernens keine Stillsetzfunktion.** Wer wirklich anhalten
will, nimmt **SCRAM** -- das wirkt in jedem Zustand, auch waehrend des
Einlernens (nachgewiesen: Zustand SAFE, Durchfluss 0, Staebe 100).

Sichtbar ist der Vorrang an drei Stellen:

| | |
|---|---|
| `status_fields().effective_percent` | die tatsaechlich wirksame Vorgabe |
| `status_fields().master_percent` | die uebermittelte |
| `status_fields().calibration_overrides_master` | beide weichen gerade ab |

Dazu eine einmalige WARN-Meldung, die den Weg zum echten Anhalten nennt.
Festgehalten in `rt2_calibration_precedence_test.lua` -- einschliesslich
der Zusicherung, dass der Vorrang selbst bestehen bleibt, damit ihn
niemand versehentlich "repariert".

### Das Anlagenmodell aus dem Mod-Quelltext

`tests/support/er_plant_model.lua` bildet die Turbine 1:1 nach dem
Quelltext von **Extreme Reactors 2.4.27 (MC 1.21.1, die Version in
ATM10 8.1)** nach -- jede Zeile hat ihre Entsprechung in
`TurbineLogic.update()`, die Kennzahlen stehen in `TurbineVariant.java`,
`TurbineData.java` und `TurbineGameData.java`. `er_rt_harness.lua` haengt
den echten RT-Stapel ueber die echten Adapter daran.

Die Kalibrierung stimmt unabhaengig nach: 80 Blaetter auf 20
Wellenbloecken mit 74 Enderium-Spulenbloecken ergeben bei 2000 mB/t
**899.6 RPM und 24.1 kFE/t** -- genau der Auslegungspunkt, auf den der
Regler zielt. Derselbe Aufbau mit Ludicrite ergibt 47 kFE/t gegen die vom
Mod-Autor genannten "rund 45K FE/t aus einer vollen Spule in einer
Reinforced-Turbine".

Vier Eigenschaften, die den frueheren Testmodellen fehlten:

1. **Die Drehzahl ist ein Integrator, keine Funktion des Durchflusses.**
   `rotorEnergy += Auftrieb - Spule - Luftwiderstand - Reibung`, und
   `rpm = rotorEnergy / (Blaetter * Rotormasse)`. Eine Stellgroesse wirkt
   also auf die ABLEITUNG der Drehzahl. Ein reiner P-Regler ueberschwingt
   hier zwangslaeufig -- deshalb der Vorhalt.
2. **Die Zeitkonstante waechst mit der Turbine.** Ein Rotor mit 80
   Blaettern auf 20 Wellenbloecken beschleunigt bei vollem Dampf und
   ausgehaengter Spule mit rund **5 RPM/s** -- von null auf 900 dauert
   drei Minuten. Kleinere Rotoren sind entsprechend schneller.
3. **Die Spule ist der groesste Term der Bilanz.** Bei 900 RPM und 74
   Enderium-Bloecken betraegt ihr Gegenmoment rund 19 980 gegen einen
   Auftrieb von 20 000. Ein- und Aushaengen dreht das Vorzeichen der
   Beschleunigung um -- siehe den naechsten Abschnitt.
4. **Der Mod begrenzt die Drehzahl NICHT.** `getMaxRotorSpeed()` taucht
   nur in der Oberflaeche und im Redstone-Port auf; in der Simulation
   steht keine Grenze. Unsere Ueberdrehzahl-Abschaltung ist die einzige.

Der Reaktor ist im Modell bewusst eine Naeherung (seine echte Kette aus
Bestrahlung, Brennstoff- und Reaktorwaerme und Verdampfung ist um ein
Vielfaches groesser als die Turbine). Modelliert ist, was der Regler von
ihm sieht: Dampfmenge, Produktion als Funktion der Stabstellung, Verbrauch
durch die Flotte, Brennstoff und Temperatur.

**Staebe am Anschlag ist der GESUNDE Zustand.** `rt2_reactor.ROD_MIN = 70`
ist eine bewusste Leistungsgrenze; Extreme Reactors senkt die Strahlung
proportional zum Stabeinschub, also sind rund 30 % des Nennwerts nutzbar.
Bei einem ausreichend grossen Reaktor deckt das den Flottenbedarf
muehelos -- und dann passiert folgendes:

`getHotFluidAmountMax` ist 1000 mB je Kuehlmittel-Port
(`ReactorVariant.setPartFluidCapacity`), nicht die 200000 Obergrenze. Die
Tankgroesse liegt damit in der Groessenordnung EINES Takts Flottenbedarf.
Weil in jedem Takt abgezogen wird, bleibt der gemessene Fuellstand
dauerhaft unter dem Sollwert von 70 % -- der Stabregler fordert also fuer
immer mehr Leistung und steht am Anschlag. Das sieht nach einem
festgefahrenen Regler aus, ist aber richtig: die Turbinen bekommen jeden
mB, den sie anfordern, nichts schwingt, und der Reaktor laeuft an seiner
erlaubten Obergrenze. Festgehalten in
`rt2_er_physics_scenarios_test.lua`, damit es niemand "repariert".

Der umgekehrte Fall -- ein Reaktor, dessen 30 % den Bedarf NICHT decken --
haengt ebenfalls bei Staeben 70, aber mit leerem Tank und einer Flotte
unter dem Zielband. Das ist eine Auslegungsfrage, kein Reglerfehler, und
der Knoten sagt es auch so ("fahren VOLLEN Durchfluss und erreichen
trotzdem keine 900 RPM -- Fehlt Dampf?").

### Ein Messausfall ist eine Sicherheitslage -- nach 30 Minuten

Faellt die Temperatur- oder Kuehlmittelmessung aus, gilt das nach
`safety.measurement_grace_samples` Takten selbst als Ausloesung. Der
Default sind **18000 Takte = 30 Minuten** bei 10 Hz (Betreibervorgabe).

Die Abwaegung dahinter gehoert dazu, weil beide Richtungen etwas kosten:

| | |
|---|---|
| zu kurz | Fehlabschaltung. Ein nachladender Chunk, ein kurz zerlegtes Multiblock, ein Peripheral-Rebind, niedrige TPS -- all das kann die Messung minutenlang verdecken, ohne dass der Anlage etwas fehlt. |
| zu lang | ein echter Sensorausfall bleibt entsprechend lange unentdeckt, und solange regelt der Knoten ohne Ueberwachung weiter. |

30 Minuten sind bewusst gross gewaehlt: der Zweck dieser Pruefung ist, dass
der Zustand nicht **unbegrenzt** als "sicher" durchgeht -- nicht, dass er
schnell auffaellt. **Sichtbar ist der Ausfall ab dem ERSTEN Takt**
(`temperature_available` / `coolant_available` samt Ausfallzaehler im
Sicherheitsergebnis). Wer frueher reagieren will, liest diese Felder,
statt die Schonfrist zu verkuerzen.

Gezaehlt wird nur ein Kanal, der auf diesem Reaktor schon einmal gelesen
wurde -- ein passiv gekuehlter Reaktor (kein Kuehlkreis, `resolve_ratio`
liefert dauerhaft nil) und eine noch nicht gebundene Peripherie loesen
damit nie aus.

**Der unbelastete Rotor ist der gefaehrlichste Zustand.** Aus denselben
Formeln: ohne eingehaengte Spule haelt ein Rotor mit 80 Blaettern die
Zieldrehzahl schon bei rund **3 mB/t**, und bei 10 mB/t -- einem einzigen
Feintrimm-Schritt -- liegt sein Gleichgewicht ueber **4000 RPM**. Mit
Spule braucht dieselbe Drehzahl 2000 mB/t. Deshalb ist "Spule drin" die
Grundstellung in jedem Fehlerfall (unlesbare Drehzahl, geworfener
Peripherieaufruf, geparkte aber noch drehende Turbine), und deshalb darf
eine einmal gekuppelte Turbine nicht wieder aushaengen.

### Einmal gekuppelt bleibt gekuppelt

Dieselbe Stelle, die andere Richtung — und der Grund fuer "eine einzelne
Turbine geht nach einiger Zeit in Ueberdrehzahl":

Unterhalb von `COIL_DISENGAGE_RPM` (850) loeste die Spule wieder. Das
sieht nach gewoehnlicher Hysterese aus, ist hier aber etwas anderes. Die
Spule ist kein kleiner Beitrag zur Last, **sie ist die Last**: Ein- und
Aushaengen aendert die Streckenverstaerkung sprunghaft um ein Mehrfaches.
Der Durchflussregler regelt dann gegen eine Strecke, die ihre
Verstaerkung im Takt wechselt, und beides schaukelt sich gegenseitig auf:

```
Spule bremst unter 850 -> loest -> Rotor schiesst hoch -> Spule greift
-> bremst unter 850 -> ...
```

Der bestehende Zwillings-Integrationstest konnte das nicht sehen: sein
Rotormodell kennt die Spule nicht, dort haengt die Drehzahl allein am
Durchfluss. Mit einem Modell **mit** Spulenlast (Kupplungslast 2x
Grundreibung, Durchfluss 1500 haelt 900 RPM) zeigt der geschlossene
Regelkreis ueber 90 s:

| | Umschaltungen | mittlere Abweichung | Drehzahlspitze |
|---|---|---|---|
| mit Loeseschwelle | ~875 | 90 RPM | waechst mit sinkender Rotortraegheit, ab 0.25 ueber 1300 |
| einmal gekuppelt = gekuppelt | 1 | 1.8 RPM | unter 1100 ueber den ganzen Traegheitsbereich |

Die Loeseschwelle war fuer den **Hochlauf** gedacht, und der ist ein
anderer Zweig: eine noch nie gekuppelte Turbine beschleunigt weiterhin
unbelastet. Ist sie einmal am Ziel gewesen, ist Halten mit Last der
richtige Betriebszustand — nur dort liefert sie ueberhaupt Energie, und
genau das verlangt `measure_capacity` (`energy > 0`).

Eine Ausnahme bleibt, sonst haengt ein Rotor dauerhaft: wenn die Spule den
Hochlauf nachweislich **verhindert**, wird sie freigegeben
(`RELEASE_STALLED`). Drei Bedingungen muessen dafuer alle gelten:

1. Drehzahl unter `COIL_STALL_RPM_FRACTION` (**0.95**) der Zieldrehzahl,
2. Durchfluss am **Anschlag** — der Regler hat keine Stellgroesse mehr,
3. Drehzahl **steigt nicht mehr** (Rate <= `SETTLE_RATE_RPM_PER_S`).

**Die Schwelle lag zuerst bei 0.5, und das war ein Fehler.** Eine Turbine,
deren Spule staerker bremst als der Dampf schieben kann, landet nicht
unter der halben Zieldrehzahl, sondern bei 750–800 RPM — also genau
zwischen Freigabeschwelle und Zielband. Sie blieb damit dauerhaft haengen.
Gemessen am Anlagenmodell (90 Enderium-Spulenbloecke auf 80 Blaettern,
Dampf im Ueberfluss, 600 s):

| Regel | rpm | Flow | Spule | im Zielband |
|---|---|---|---|---|
| Freigabe unter 0.5 | 749 | 2000 | drin | 2,2 % |
| Loeseschwelle vor v798 | 853 | 2000 | raus | 15,6 % |
| Freigabe unter 0.95 | 875 | 2000 | drin | **20,9 %** |

Im Betrieb sah das aus wie drei verschiedene Fehler: "Spule auch unter 900
aktiv", "Flow dauerhaft 2000 obwohl RPM darueber" (auf dem Weg nach unten)
und "das Einlernen findet keine Turbinen im Zielbereich" — das verlangt
`|rpm-900| <= LEARN_TOLERANCE_RPM`, und die Turbine kam dort nie hin.

**Dass 0.95 trotz der Naehe zum Zielband nicht flattert**, liegt an den
Bedingungen 2 und 3. Im ausgelegten Betrieb steht der Durchfluss nicht am
Anschlag, oder die Drehzahl liegt im Band — die Freigabe kann dort gar
nicht greifen (nachgemessen: identische Drehzahl, identischer Durchfluss,
EINE Kupplung, identischer Ausstoss). Und eine noch steigende Drehzahl
heisst, dass die Spule den Hochlauf gerade nicht verhindert; unmittelbar
nach einer Freigabe steigt sie, die Freigabe kann also nicht im Takt
wiederkehren. Die Spitzendrehzahl blieb in jedem geprueften Fall unter 900.

Die Rate kommt fuer Durchfluss- und Spulenentscheidung aus **einer**
Quelle (`rt2_turbine.compute_rate`), damit sie nicht auseinanderdriften.

Ohne bekannten Durchfluss wird nicht freigegeben: unbekannt ist kein
Nachweis. Festgehalten in `rt2_coil_hold_limit_cycle_test.lua` und
`rt2_coil_stall_release_test.lua`; den Verhaltensnachweis am echten
Adapterstapel fuehrt `rt2_er_physics_scenarios_test.lua`.

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
| `rt2_coil_hold_limit_cycle_test.lua` | geschlossener Regelkreis MIT Spulenlast: kein Grenzzyklus, keine Ueberdrehzahl |
| `rt2_coil_stall_release_test.lua` | Notfreigabe der Spule: haengt keine Turbine unter dem Zielband fest |
| `rt2_er_physics_integration_test.lua` | ganzer Stapel gegen die Turbinenphysik aus dem Mod-Quelltext |
| `rt2_er_physics_scenarios_test.lua` | Basic-Turbinen am Anschlag, knapper Dampf, MASTER-Vorgabe mit Slot-Rotation |
| `rt2_calibration_precedence_test.lua` | Einlernen ueberstimmt die MASTER-Vorgabe -- gewollt, sichtbar, und SCRAM wirkt trotzdem |
| `rt2_safety_measurement_loss_test.lua` | fehlende Sicherheitsmessungen: Schonfrist, Ausloesung, Erholung |
| `rt2_unreadable_flow_commands_zero_test.lua` | unbekannter Durchfluss wird nie als 0 geschrieben |
| `rt2_fuel_chain_test.lua` | Reaktor-Fuellstand bis zur FUEL-Node (beide Wege) |
| `rt2_monitor_v2_display_test.lua` | RT-Schirm zeigt den wirklichen Zustand |
| `rt_boot_smoke_test.lua` | Kaltstart der ganzen Rolle auf einer simulierten Anlage |
| `rt2_learning_test.lua` | Einlernen: 80 %, Zielband, Hoechstwert, Warten statt Abbruch, Umbau |
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
