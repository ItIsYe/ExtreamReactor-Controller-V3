# Session Handoff — XReactor Controller V3

**Stand: 2026-09-25 | beta | manifest-v737**

## Rollback-Marken

| Marke | Commit | Stand |
|---|---|---|
| `stable-beta-v761` | `f348d4ba` | **aktuell gueltig.** RT-Regler im Betrieb bestaetigt, FUEL liefert, Dampftank-Sollwert 70 % |
| `stable-beta-v742` | `ac122a05` | vorherige Marke (RT bestaetigt mit 1 Reaktor / 25 Turbinen, FUEL noch defekt) |

Eine Marke ist ein **Branch**, kein Tag: Tag-Pushes scheitern in dieser
Umgebung reproduzierbar (`send-pack: unexpected disconnect`), Branches
nicht.

### Warum v761 die neue Marke ist

Dazwischen liegt ein Umweg, der festgehalten gehoert:

- **v743-v750 FUEL, geloest und bestaetigt.** Ursache war die
  Aufrufkonvention der ME Bridge -- die Advanced-Peripherals-Doku nennt
  `exportItemToPeripheral(item, container)`, das gilt aber nur bis 0.7;
  die 1.21-Fassung nimmt sie nicht an. Verdeckt wurde das von sieben
  Ausstiegen im Lieferpfad, die still oder nur in den Log-Collector
  schrieben.
- **v754-v757 RT, zurueckgenommen.** Ein gestaffeltes Einlernen sollte
  verhindern, dass sich eine grosse Flotte selbst den Dampf wegnimmt. Es
  brach dabei die Entkopplung: "Turbinen erreichen ihr Ziel nicht" ist
  eine FOLGE von wenig Dampf, und daraufhin wurde die Turbinen-Freigabe
  gedrosselt -- damit regelte der Tankstand die Turbinen. Ergebnis im
  Betrieb: von 50 Turbinen lief eine. v755-v757 haben anschliessend nur
  die Folgefehler geflickt, statt die Annahme zu pruefen.
- **v759 vollstaendiger RT-Rollback**, `nodes/rt/` bitweise auf v742.
- **v760** Der Rollback allein half nicht: die gelernten Dateien liegen
  NEBEN dem Code auf dem Rechner und ueberleben ihn. Ein von der
  fehlerhaften Fassung gespeichertes `sustainable_turbines = 1` wurde
  anstandslos wieder eingelesen. Alle drei gelernten Dateien tragen jetzt
  ihre Lernfassung (nicht die Release-Nummer -- sonst wuerfe jedes Update
  das Gelernte weg).
- **v761** Dampftank-Sollwert 50 % -> 70 % auf Betreibervorgabe.

**Regel daraus:** eine Groesse aus dem Reaktorkreis darf die
Turbinenregelung nicht beeinflussen. Festgehalten in
`tests/rt2_turbine_flow_decoupled_from_tank_test.lua` -- derselbe Takt
mit leerem und mit vollem Tank muss identische Turbinenentscheidungen
liefern.

## Aktueller Zustand: stabil, alles auf `beta`

Kein offener PR, keine offene Issue. `beta` ist der aktive Entwicklungszweig;
`main` bleibt unangetastet (stabile Releases, nie direkt bearbeiten).

### Turbinen-Selbstvermessung — zurueckgenommen und gefixt wieder drin

Der Regler-Umbau (Stellintervall, Vorausschau, Ruhezone, gelernte
Kennlinie je Turbine — `rt2_turbine_model.lua`) lief im ersten Anlauf
(v734) im Spiel auf: 25 Turbinen bei 967–1256 RPM, voller Durchfluss,
geloeste Spule, keine Reaktion. Zurueckgenommen in v737.

Ursache gefunden und nachgemessen: nicht die Regellogik, sondern die
Schreibersparnis. `rt2_adapter.read_turbine()` machte aus einem
unlesbaren Durchfluss (`"n/a"`) eine `0`, und der Dirty-Check hielt
diese erfundene 0 fuer einen echten Rueckmesswert — ein einziger
fehlgeschlagener Peripherieaufruf stellte das Schreiben damit dauerhaft
ein. Details in [`RT_ENGINE_V2.md`](RT_ENGINE_V2.md), Abschnitt
„Selbstvermessung der Turbinen".

Wieder drin seit v738, mit Fix und `rt2_unreadable_turbine_write_test.lua`.

Seit v739 ist auch die **Ursache der unlesbaren Messwerte** beseitigt:
`adapters/turbine.lua` fiel bei einer fehlgeschlagenen
Faehigkeitsabfrage auf `getRotorRPM` zurueck — eine Methode, die es bei
Extreme Reactors 2 nicht gibt, und deren Aufruf CC:Tweaked mit
`No such method` quittiert. Faehigkeiten werden jetzt je Peripherie
gemerkt und es wird nie eine Methode aufgerufen, von der nicht bekannt
ist, dass es sie gibt (`turbine_adapter_capability_probe_test.lua`).

**Im Betrieb bestaetigt (2026-09-25):** ein Reaktor mit 25 Turbinen
laeuft im Spiel einwandfrei, der Regler bleibt ruhig und haelt die
Drehzahl. Ebenfalls bestaetigt: Lastwechsel, und der gemeldete Ausstoss passt zu
dem, was an der ENERGY-Node ankommt. Zwei Reaktoren liefen zunaechst
NICHT (einer geregelt, einer nicht) -- behoben in v742, im Spiel noch
nicht nachgeprueft. Nicht bestaetigt bleibt mehr als 25 Turbinen. Die gelernte Kennlinie war nicht beteiligt --
ohne Lastwechsel entsteht kein zweiter Betriebspunkt.

### Platzbedarf auf dem Knoten

Ein CC-Rechner hat voreingestellt 1 MB. Die Rollen brauchen (mit allen
Zusatzfunktionen):

| Rolle | Dateien | Installation |
|---|---|---|
| RT | 76 | 831 kB |
| MASTER | 71 | 708 kB |
| FUEL | 63 | 604 kB |
| ENERGY | 52 | 461 kB |
| REPROCESSING | 49 | 435 kB |
| VALVE | 32 | 295 kB |
| WATER | 44 | 373 kB |
| LOG | 16 | 147 kB |

RT liegt damit bei rund 83 % eines voreingestellten Rechners — plus
`/xreactor_config`, `/xreactor_logs` und `/startup.lua`. **Fuer RT gehoert
`computer_space_limit` hochgesetzt** (`serverconfig/computercraft-server.toml`).

Zwei Dinge dazu sind seit v735/v736 anders:

- Der Installer prueft den Platz, **bevor** er die alte Installation
  loescht (`stage.check_capacity`). Reicht er nicht, bricht er ab und der
  Knoten laeuft unveraendert weiter. Vorher lief er bis zur letzten Datei
  und liess den Rechner halb installiert liegen.
- Die Installermodule und `manifest.lua` werden nicht mehr mitinstalliert
  (95 kB je Knoten). Ein Knoten liest keines davon je von der Platte: der
  Bootstrap `/installer` laedt seine Module bei jedem Lauf frisch von
  GitHub, und die Buildkennung kommt aus `release.lua`. Einzige Ausnahme
  ist `installer/auto_update.lua`, das `start.lua` laedt. Festgehalten in
  `installer_node_footprint_test.lua`.

Weiteres Sparpotenzial gibt es auf Dateiebene **nicht** — jede noch
installierte RT-Datei ist vom Einstieg aus erreichbar. Der naechste grosse
Posten waere der v1-Regelstapel (rund 191 kB: `turbine_control`,
`reactor_control`, `module_lifecycle`, `state_handlers`, `command_handler`,
`core/turbine_regulator`, `core/control_rails` …), der erst entfallen kann,
wenn v2 v1 endgueltig ersetzt.

### RT-Regel-Engine v2 — laufender Umbau

Der RT-Knoten hat seit 2026-09 eine zweite Regel-Engine (`rt2_*.lua`),
aktivierbar **pro Knoten** mit `engine = "v2"` in `/xreactor_config/rt.lua`.
Ohne den Eintrag laeuft alles unveraendert auf v1. Vollstaendige
Beschreibung: [`RT_ENGINE_V2.md`](RT_ENGINE_V2.md).

Stand:

- Ein einziger Zustandsautomat statt zweier paralleler Systeme; der
  Betriebsmodus wird nicht mehr befohlen, sondern ergibt sich aus der
  MASTER-Verbindung.
- Der Reaktor regelt in JEDEM Zustand nur aus seinem eigenen Dampftank.
- Mehrere Reaktoren an einem Knoten werden unterstuetzt: eine
  Turbinenflotte an einem gemeinsamen Dampfnetz, jeder Reaktor regelt
  unabhaengig aus SEINEM Tank. Keine Zuordnung Turbine -> Reaktor noetig.
  Turbinenzahl nicht begrenzt (nachgemessen bis 100).
- Ein Sicherheitsausloeser faehrt nur seinen eigenen Reaktor ein; erst
  wenn keiner mehr regelbar ist, geht der Knoten auf SAFE.
- Einlernen misst den hoechsten tatsaechlich geflossenen Gesamtausstoss
  (80 % der Flotte muessen dabei gleichzeitig im Zielbereich sein) --
  nicht mehr hochgerechnet.
- Jeder Reaktor vermisst seine eigene Anlage einmalig selbst und leitet
  daraus Stellintervall und Schrittweite ab.

**Offen: der Livetest.** Alle Aussagen stammen aus Tests gegen ein
vereinfachtes Anlagenmodell. Ob v2 v1 ersetzt, ist NICHT beschlossen.

## Architektur-Grundlagen (weiterhin gültig)

- Config (`role.lua`, `node_id.txt`, `reactor_names.lua`, `*_routes.lua`,
  Registry-Dateien) liegt unter `/xreactor_config/` — außerhalb des Baums,
  den der Installer bei jeder (Re-)Installation komplett löscht und neu
  aufbaut. Config wird dadurch nie gelöscht.
- FUEL/WATER/REPROCESSING/RT/VALVE laufen seit PR #543/#544 auf einem
  geteilten Event-Loop (`nodes/support/runtime.lua`'s `run_fast_loop()` +
  `run_slow_loop()`, via `parallel.waitForAny()`): sicherheits-/UI-kritische
  Arbeit (Touch, Comms, Aktor-Ticks) im fast-Loop, langsame Peripherie-Arbeit
  (Discovery, ME-Bridge-Reads, Telemetry) im slow-Loop — verhindert, dass
  eine langsame Peripherie-Abfrage die Touch-UI einfriert. MASTER/ENERGY/
  LOG_COLLECTOR nutzen weiterhin das ältere, ungeteilte `run_event_loop()`.
- `xreactor/release.lua`'s `commit_sha` bleibt IMMER `"beta"` (nicht der
  echte Git-SHA) — `scripts/package_release.py --sync` setzt ihn
  versehentlich auf den echten SHA; nach jedem `--sync`-Lauf manuell
  zurück auf `"beta"` prüfen (siehe `tests/release_metadata_consistency_test.lua`).
- `scripts/package_release.py --sync` erzeugt zusätzlich ein untracked
  `dist/xreactor-release.zip` — nach dem Lauf entfernen (`rm -rf dist`).
- Manifest und `release.lua` vor jedem Commit manuell resynchronisieren
  (`python3 scripts/manifest_sync.py --write`) — CI prüft nur (`--check`),
  aktualisiert aber nichts automatisch.

## Regler-Aufzeichnung auf dem Knoten (v779)

Betreiberauftrag: "Der Regler spinnt immer noch rum -- lege ein Logging vom
Regler und von den Turbinen lokal auf der Node ab, um endgueltig zu sehen,
was da los ist."

**Datei:** `/xreactor_logs/rt_trace_<node_id>.csv` auf dem **Rechner**, nicht
auf der Diskette (eine CC-Diskette hat 125 KB fuer alles zusammen). Rotiert
bei 64 KB, drei Dateien, also hoechstens 192 KB. Abschalten:
`trace = { enabled = false }` in `/xreactor_config/rt.lua`.

**Was drinsteht — die Kette, die bisher fehlte.** Logzeilen und Schirm
zeigten je ein Drittel: entweder einen Messwert, oder eine Entscheidung,
oder ein Ergebnis. Nie alle drei nebeneinander, also nie gegeneinander
pruefbar. Jetzt pro Zeile: Messwert → Entscheidung → Schreibaufruf →
Rueckmeldung.

Zwei Felder, die es vorher nirgends gab:
* **`unchanged`** — der Regler schreibt NICHT, wenn der zurueckgelesene Wert
  schon der gewuenschte ist. Luegt der Rueckmesswert, steht die Turbine fuer
  immer falsch, ohne eine einzige Fehlermeldung. Das ist die
  wahrscheinlichste Erklaerung fuer "Flow 0 auf der ganzen Flotte", und sie
  war bisher unsichtbar.
* **die Rueckgabe von `rt2_adapter.apply_turbine()`** (`write_ok`/`write_err`,
  `coil_ok`/`coil_err`) — sie sagt, ob der Schreibaufruf losging.
  `rt2_engine` hat sie bis v779 verworfen.

**Leer heisst unbekannt, 0 heisst null.** Genau diese Verwechslung hat einen
ganzen Tag gekostet. In der Datei sind sie unterscheidbar.

**Datenmenge.** Bei 50 Turbinen und 10 Hz waeren es 500 Zeilen je Sekunde.
Deshalb: Sammelzeile je 2 s, Reaktorzeilen dazu, Turbinenzeilen **nur bei
Aenderung** (Grund, Sollwert, Schreibfehler) — eine eingeschwungene Flotte
schreibt fast nichts, eine zappelnde genau ihre Zappler. Immer geschrieben
werden ausserdem ein fehlgeschlagenes Schreiben und ein Durchfluss 0 trotz
vorgegebenem Ziel: gerade das Verharren ist der Befund. Alle 60 s ein
vollstaendiger Abdruck aller Turbinen als Grundwahrheit — der wird NICHT
gekappt, ihn zu kuerzen hiesse, ihn nicht zu machen.

**Bauform:** `rt2_trace.lua` ist rein (Zeilen bauen, testbar ohne
Dateisystem), `rt2_trace_writer.lua` macht die Datei-Arbeit. Jeder
Dateizugriff laeuft in `pcall` und schlaegt still fehl — eine volle Platte
kostet eine Zeile, nie einen Regeltakt. Gepuffert wird, damit bei 10 Hz
nicht zehnmal je Sekunde eine Datei geoeffnet wird.

Tests: `rt2_trace_format_test.lua` (Unbekannt vs. 0, Unterdrueckung von
Wiederholungen, Befunde trotzdem, Zaehler, Kommas im Fehlertext),
`rt2_trace_writer_test.lua` (Kopfzeile, Flush-Takt, Rotation deckelt,
kaputte Platte schlaegt nicht durch), und `rt_boot_smoke_test.lua` prueft im
echten Lauf, dass die Datei entsteht, die Spaltenzahl je Zeilenart konstant
bleibt und der Wechsel LEARNING → AUTONOM darin auftaucht.

## MASTERs Startup-Sequencer: Ursache gefunden (v777/v778)

**Der Timeout.** Im Feld: `Timeout stage=WAITING_ACK elapsed=60.2s`,
Warteschlange 51/52. Die Zuordnung der Quittung haengt an genau einem
Feld: `message_handlers.lua` reicht `result.module_id` aus dem ACK an
`startup_sequencer.lua`s `notify_ack()`, das es gegen
`self.active.module_id` vergleicht. v1s `command_handler.lua` gab
`module_id = module.id` mit — beim Umstieg auf den rt2-Regler ging das
Feld verloren, `rt2_command_handler` kannte nur ok/effects. MASTER verglich
also gegen `nil`, bei jedem Modul, bei jeder Node.

Das war nicht folgenlos: `handle_timeout()` verwirft die **ganze**
Warteschlange, schickt `MODE=LIMITED` (oder EMERGENCY) und meldet einen
Alarm. Dass an der Anlage nichts zu sehen war, liegt nur daran, dass
`MODE` im rt2-Handler bewusst ein No-Op ist.

Behoben auf der **RT-Seite** (v777), damit MASTERs laufender Kommandopfad
unangetastet bleibt: die Node echot die empfangene `module_id` zurueck.
Ein Echo kann per Konstruktion nicht danebenliegen — verglichen wird gegen
das, was MASTER selbst gesendet hat. Test
`master_rt_startup_ack_correlation_test.lua` verdrahtet beide echten
Seiten gegeneinander (kein Nachbau der Quittung — genau der hatte die
Luecke ja nicht) und prueft auch die Gegenrichtung: eine fremde oder
fehlende id darf einen Schritt NICHT abschliessen.

**Der Beifang, und der war gefaehrlicher.** `should_emergency()` stuft
einen Timeout als EMERGENCY statt LIMITED ein, wenn
`snapshot.max_temp > config.scram_temperature`. Der Rueckfallwert war fest
**950 °C** — und `scram_temperature` wird nirgends im Projekt gesetzt, der
Rueckfall greift also immer. RTs eigene Trip-Grenze liegt bei **2000 °C**
(mit Hysterese und 3 Messwerten Entprellung); eine aktiv gekuehlte Anlage
faehrt im Normalbetrieb darueber. Aufgefallen ist das nie, weil
`snapshot.max_temp` bis v776 nie ankam — **mein eigener Snapshot-Fix haette
den Pfad scharf gemacht** und aus jedem Timeout einen EMERGENCY-Alarm bei
normaler Betriebstemperatur.

Auf Betreiberentscheidung auf 2000 angeglichen (v778), als benannte
Konstante `sequencer.DEFAULT_SCRAM_TEMPERATURE`.
`master_scram_threshold_matches_rt_limit_test.lua` haelt beide Zahlen
zusammen und prueft die Folge: bei 1600 °C darf MASTER keinen Notfall
sehen, bei 2050 °C schon. Die Richtung ist die sichere — MASTER wird
weniger ausloesefreudig, nicht mehr. Verloren geht dabei nichts: RT trippt
selbst bei 2000, und `MODE` ist auf der Node ohnehin ein No-Op.

## Verdrahtungs-Durchgang nach dem v1-Ausbau (v776)

Betreiberauftrag: "Gehe noch mal alles durch, ob alles noch richtig
verdrahtet ist, ob die Logik/Regler noch funktionieren und ob noch
irgendwo toter Code ist." Durchgefuehrt. Ergebnis:

**Regler laeuft — im Lauf nachgewiesen, nicht nur behauptet.**
`tests/rt_boot_smoke_test.lua` bootet `nodes/rt/main.lua` echt und faehrt
die Anlage im **geschlossenen Regelkreis** (Durchfluss treibt die Drehzahl
traege, ausgefahrene Staebe erzeugen Dampf, die Turbinen verbrauchen ihn —
die Rueckkopplung laeuft also ueber den Dampf, wie vorgesehen). Mit 2
Reaktoren und 50 Turbinen, aus einer alten `rt.lua` mit `engine = "v1"`:
Einlernen wird fertig (1.30 M RF/t), alle 50 Turbinen stehen bei 899–901
RPM, die Staebe regeln auf 85 % (strikt zwischen 70 und 100 — also wird
wirklich gestellt), der Tank haelt 0.65–0.67 gegen Soll 0.70, alle 52
Module projizieren `STABLE`, und ein **leergefahrener Tank drosselt die
Turbinen nicht**.

**Toter Code — vier Stellen, alle entfernt:**
* `main.lua`: `broadcast_status()` (mit v1s Aufrufern entfallen)
* `main.lua`: `ctx.reactor_control`, `ctx.get_turbine_ctrl` (v1-Querverweise)
* `reactor_control.has_reactor_rod_write_path()` — dazu hatte ich selbst
  einen falschen Kommentar geschrieben ("genutzt von der Discovery"); sie
  wurde von nirgends aufgerufen, `binding.lua` hat eigene Logik
* `status_snapshot.update_status_snapshot()` — reiner Durchreicher, den
  niemand aufrief
* `rt2_engine.lua`: ungenutztes `require("nodes.rt.rt2_reactor")`

**Ein echter Verdrahtungsfehler, aelter als der Umbau — behoben:**
`payload.snapshot` war das **Modul** `status_snapshot.lua` selbst
(`snapshot = ctx.status_snapshot`, und unter diesem Namen reicht `main.lua`
das Modul herein) — eine Tabelle voller Funktionen. MASTER liest daraus in
`startup_sequencer.lua` genau zwei Werte: `snapshot.avg_rpm` und
`snapshot.max_temp`, letzteres in `should_emergency()`. **MASTERs
Temperatur-SCRAM ueber den RT-Snapshot konnte damit nie ausloesen.** Jetzt
aus den Aufnahmen gebildet, die derselbe Aufruf ohnehin hat (kein zweiter
Peripherie-Durchgang); `reactors[].temperature` wird zusaetzlich
mitgeschickt. Festgehalten in
`tests/rt_status_snapshot_master_fields_test.lua`.

**Eine kleinere Luecke, ebenfalls aelter — behoben:** `monitor_ctx`
enthielt nie `monitor_scale`, obwohl `monitor_ui.lua` es fuer die
Diagnoseseite liest. Der Wert wurde korrekt gefuehrt und persistiert, nur
nie angezeigt.

**Sauber:** alle `ctx`-Felder, die RT-Module lesen, werden geliefert (je
Verbraucher geprueft: Hardware-Module, `status_snapshot`, `monitor_ui`,
`health_payload`); keine verwaisten Dateien; keine ungenutzten
`require`s; kein toter Export und kein toter lokaler Helfer mehr im
RT-Knoten.

**Offen geblieben (nicht von diesem Umbau verursacht):** MASTERs
Startup-Sequencer lief im Feld in `Timeout stage=WAITING_ACK elapsed=60.2s`
mit Warteschlange 51/52. Die Projektion liefert `STABLE` (52/52 im Lauf
nachgewiesen), die Ursache liegt also auf der MASTER-Seite oder im
ACK-Weg. Ebenso offen: `Config issue (lua invalid) at /xreactor_config/
rt.lua` (vermutlich fehlendes `return`) und `Reactor_9`s Staebe, die im
Feld nur 97 statt 100 erreichten.

## v1 ist raus — die RT-Node hat genau einen Regler (v769)

Betreibervorgabe: "Nimm die v1 komplett raus. V2 wird jetzt Standard fuer
RT." Umgesetzt.

**Entfernt** (ersatzlos, nicht deaktiviert): `state_handlers.lua`,
`module_lifecycle.lua`, `command_handler.lua`, `startup_diagnostics.lua`,
`capacity_learning.lua`, `capacity_cache.lua`, `flow_apply_helpers.lua`,
`reactor_steam_guard.lua` sowie `core/turbine_regulator.lua`,
`core/control_rails.lua` und `core/state_machine.lua` (nur v1 nutzte sie).
Dazu 49 Testdateien, die ausschliesslich v1 beschrieben. Unterm Strich
rund 8.700 Zeilen weniger.

**Geblieben, aber entkernt**: `reactor_control.lua` (919 → 248 Zeilen) und
`turbine_control.lua` (1032 → 263 Zeilen). Sie regeln nichts mehr. Was
bleibt, ist Hardwarezugriff, den auch v2 braucht: Capability-Discovery,
Drehzahl-/Durchfluss-/Dampfmessung fuer Statusaufnahme und Schirm, die
initiale Rod-Stellung, und der Sicherheitszustand fuer den Update-Quiesce
(der gehoert dem Updater, nicht dem Regler). Die Modulkoepfe sagen das.

**Der `engine`-Schalter ist weg.** Sein Default war `"v1"` — jede frisch
vom Installer angelegte `rt.lua` lief also im alten Regler. Ein noch
vorhandenes Feld entfernt der `config_normalizer` beim naechsten Schreiben
mit einer Warnung; die Installer-Vorlage nennt es nicht mehr.

**Was das aendert:** `control_tick()` ist jetzt Quiesce-Sperre plus
`rt2_engine.tick(ctx)` — sonst nichts. Kein Modul-Lebenszyklus, keine
Startup-Warteschlange, kein Startup-Watchdog, keine Knoten-Zustands-
maschine. Statuspayload und Schirm lesen ihre Entscheidungswerte (Modus,
Knotenzustand, Kapazitaet) nur noch aus `rt2_engine.status_fields()`; die
Hardwareaufnahme daneben bleibt unveraendert.

**Bewusst mitgestrichen:**
* `ramp_state` im Statuspayload (trug unter v2 ohnehin nur `nil`; MASTER
  liest es nil-sicher und nutzt es nur als Aenderungs-Marker).
* `SET_REACTOR_FILL_TARGET` — das Kommando lebte nur im v1-Handler und war
  seit dem Umstieg auf v2 unerreichbar. Entfaellt ersatzlos.

**Der Dampftank-Sollwert ist ein fester Wert** (Betreiberentscheidung,
nachgefragt und bestaetigt): `rt2_reactor.DEFAULT_TARGET_FILL = 0.7`, weder
per Konfiguration noch per Kommando aenderbar. Er beschreibt die Anlage,
nicht den Betriebspunkt — den stellt MASTER ueber die Leistungsvorgabe, und
die wirkt ueber die Turbinen auf den Tankstand, nicht ueber diesen Wert.
Das tote Durchreichen von `target_fill` in `rt2_unit.lua` ist entfernt: es
hat nie jemand gesetzt und sah nur wie ein Knopf aus. Der Parameter in
`rt2_reactor.compute_rod_level()` bleibt als Test-Naht, damit das
Regelgesetz gegen mehrere Sollwerte pruefbar ist, ohne die Konstante
anzufassen.

**Neu abgesichert:** `tests/rt_boot_smoke_test.lua` bootet
`nodes/rt/main.lua` wirklich — gegen gestubbte CC:Tweaked-Peripherie, mit
2 Reaktoren und 50 Turbinen und einer alten `rt.lua`, die noch
`engine = "v1"` enthaelt. Geprueft wird: der Boot laeuft durch, kein
v1-Modul ist danach geladen, die Anlage ist vollstaendig erkannt, und nach
40 Regeltakten hat der Regler ALLE 50 Turbinen angesteuert (Flow > 0) --
genau das Bild, das im Feld fehlte. main.lua ist ein Boot-Skript und nicht
require()-bar; ohne diesen Test faellt ein nil-Zugriff in `init()` erst auf
dem Computer auf, als abgestuerzte Node.

## Der stornierte Update-Quiesce — wie v1 doch in v2 eingreift (v768)

Betreiberfrage: "Kann das auch eine Sache sein, dass v1 in v2 eingreift?
Bei v1 hatte das mit dem Doppelsetup geklappt." — Ja, aber nicht dort, wo
man es vermutet. v1s Regler laeuft unter v2 nicht mit: `control_tick()`
kehrt bei `engine_v2` sofort zurueck, `node_state_machine:tick()` wird nie
gefahren, `handle_command_v2` ersetzt v1s Command-Handler. Der einzige v1-
Code, der unter v2 noch an die Hardware schreibt, ist der Sicherheits-
Schreiber des Update-Pfads — und der hatte keinen Rueckweg.

Ablauf: Der Auto-Updater fordert vor jedem Update einen Quiesce an. RTs
`update_quiesce_safe()` setzt daraufhin `rt_update_quiescing = true`,
schreibt **auf allen Turbinen Flow 0, haengt alle Coils ein** und faehrt die
Staebe auf 100%. Ab da kehrt `control_tick()` bei jedem Takt sofort zurueck:
weder v1 noch v2 regelt noch. Bestaetigt wird der Quiesce nur, wenn **jede**
Turbine Flow 0, inaktiv und Coil eingehaengt zurueckmeldet — mit 50 Turbinen
deutlich seltener vollstaendig als mit 25. Bricht der Updater danach ab
(`installer/auto_update.lua`s `recover_unexpected()` ruft im Zustand
`QUIESCE_REQUESTED` `update_handshake.reset()` — **ohne** Reboot), bleibt die
Node dauerhaft in diesem Zustand stehen. Nur ein Reboot half.

Das erklaert die Symptomkombination, die jede andere Theorie ueberlebt hat:
flottenweit, unabhaengig vom MASTER, unabhaengig vom Readback, Drehzahlen in
der Anzeige weiterhin aktuell (der Status-Snapshot liest die Hardware
unabhaengig von `control_tick()`) — und vor allem **Coils eingehaengt,
obwohl die Drehzahl nicht im Zielband ist**: das entscheidet kein Regler so,
das ist genau der Zustand, den `apply_update_quiesce()` schreibt.

`update_handshake.reset()` sagt seinen Vertrag selbst: "Only cancel a
request while the role is still running." Die Rolle laeuft danach also
weiter und muss ihren Sicherheitszustand wieder verlassen. Seit v768 tut sie
das: `runtime.lua` meldet die Ruecknahme ueber `on_quiesce_cancelled`, RT
loest damit die Regelsperre (`update_quiesce_resume()`), FUEL seine
Liefersperre (`redstone_router:cancel_quiesce()`). Ein **bestaetigter**
Quiesce wird bewusst nicht zurueckgenommen — ab da gehoert die Hardware dem
gestoppten Runtime-Zustand, Erholung heisst Reboot. Zusaetzlich sagt RT den
Halt jetzt einmal laut (Log + `print`), statt ihn als "Flow 0" zu tarnen.

Test: `tests/quiesce_cancel_resumes_control_test.lua` (gegen v767
nachgewiesen: Storno wird dort nie gemeldet, die Sperre bleibt).

## FUEL-Logistik: warum nie Brennstoff ankam (v743–v750, geloest)

Im Betrieb bestaetigt: **FUEL liefert.** Die Ursache war eine einzige
Zeile, verdeckt von einer Kette stiller Ausstiege.

**Die Ursache.** `me_bridge_compat.export_to()` rief
`exportItemToPeripheral(item, container)` — die von Advanced Peripherals
fuer **0.7 und aelter** dokumentierte Reihenfolge. Die 1.21-Fassung (0.8,
neues ME/RS-Bridge-System) nimmt sie nicht an und antwortet mit
`bad argument #1 (string expected, got table)`. Der Aufruf erreichte den
Mod nie. Seit v749 wird die Konvention **ermittelt statt angenommen**
(gleiches Vorgehen wie `adapters/turbine.lua`), und **nur nach einem
Argumentfehler** weiterprobiert — der entsteht, bevor der Mod etwas
bewegt, ein Fehlversuch kann also nichts verschieben. Jede andere Antwort
gilt als endgueltig; ein zweiter Versuch koennte sonst doppelt liefern.

**Warum es so lange unsichtbar blieb.** Der Lieferpfad hatte sieben
Ausstiege, die entweder voellig still waren oder nur `DEBUG`/`warn_once()`
schrieben — also in den Log-Collector, nie auf den Schirm, und `warn_once`
ausserdem nur ein einziges Mal:

- Export meldet Erfolg und bewegt **null** Stueck (v746)
- die ME Bridge **lehnt ab** (v748) — genau hier steckte die Ursache
- `min_in_me` haelt den ganzen Bestand zurueck (v748)
- keine lieferbare Form der Fuel-Familie (v748)
- Ventilweg nicht stellbar, Router beschaeftigt/gesperrt (v748)

Dazu zwei Anzeigefehler, die aktiv in die Irre fuehrten: der Grund wurde
nur bei `exported > 0` geraeumt — was eine **geroutete** Lieferung nie
erreicht, sie kehrt sofort zurueck (v747) — und der Entprellungs-
Schluessel war der Meldungstext samt Sekundenzaehler, was denselben Satz
Zeile fuer Zeile auf den Schirm schrieb (v745).

**Der zweite echte Defekt (v750).** `_run_supply()` steigt bei gesetztem
`current_request` ganz oben aus. Kam der Abschluss-Rueckruf des
Ventil-Routers nie an, blieb der Knoten **fuer immer** stehen. Die
angezeigte Phase stammte dabei aus der Vorbelegung und wurde nur in
`get_summary()` nachgezogen — „seit 33s in Phase BLOCKING" war unmoeglich
(BLOCKING hat 15s Frist) und kostete eine Runde Fehlersuche. Die Phase
kommt jetzt live vom Router, und ohne laufende Transaktion wird die
Lieferung nach 45s freigegeben.

**Regel daraus:** kein Ausstieg aus einem Wirkpfad ohne ablesbaren Grund
am Rechner selbst. `utils.log()` routet zum Log-Collector — das ist keine
Anzeige. Und: eine Mod-API-Signatur, die nur fuer eine aeltere Version
dokumentiert ist, wird gemessen, nicht angenommen.

## FUEL-Logistik (Stand PR #547–#550)

- Ein gemeinsamer `export_chest` für alle Reaktoren; welcher Reaktor
  tatsächlich beliefert wird, entscheidet ausschließlich, welcher
  VALVE-Pfad geöffnet ist (`redstone_router.lua`'s `begin_transaction()`,
  blockiert immer erst alle anderen Pfade). Die Export-Kiste selbst
  braucht kein eigenes Ventil.
- `resupply_cooldown_s` (Default 30s) verhindert, dass FUEL bei jedem
  ~5s-Zyklus erneut nachlegt, solange der Reaktor eine vorige Lieferung
  noch nicht verbraucht/gemeldet hat (Feldbericht: Fuel staute sich sonst
  vor dem Reaktor).
- `logistics.enabled` ist ein bewusster Sicherheits-Default (`false`),
  nie automatisch gesetzt — Touch-Button auf der Router-Seite schaltet ihn um.
- **Hop-Timing** (PR #550, optional): VALVE-Nodes mit lokal verkabelter
  Kreuzungskiste (`config.hop_chest`, `nil` = deaktiviert) melden passiv
  deren Inhalt über den bestehenden Funkkanal. `nodes/fuel/hop_timing.lua`
  lernt daraus reale Transitzeiten pro Streckenabschnitt und macht
  `valve_open_ms` distanzabhängig statt eines festen globalen Werts —
  ohne gelernte Daten bleibt der Timeout exakt der konfigurierte Default,
  unabhängig von der Pfadlänge. Ohne konfigurierte `hop_chest` ändert sich
  am Verhalten nichts.

## VALVE-Node (Stand PR #551)

Optionale lokale 51×19-Terminal-UI am Ventil-Computer selbst
(`nodes/valve/local_ui.lua`): zeigt Status, Master-Verbindung, Pairing,
Hop-Reporter-Status. Genau eine Aktion — SAFE BLOCKIEREN (erzwingt
`apply_valve(true, true)`) — kein lokales Öffnen möglich, das bleibt
exklusiv dem FUEL/VALVE-Netzwerkkommando vorbehalten.

## FUEL-UI (Stand PR #548)

Fest auf 82×40 (8×6 Advanced Monitor, TextScale 1.0) umgestellt, keine
responsive/Legacy-Variante mehr — bei falscher Monitorgröße erscheint ein
Fehlerbildschirm statt eines UI-Fallbacks.

## ⛔ Nicht nochmal einbauen — gescheiterte Ansätze

### http.get mit Options-Tabelle
- `http.get(url, nil, { timeout = 15 })` → "bad argument #3 (boolean expected, got table)"
- CC:Tweaked unterstützt keine Options-Tabelle als dritten Parameter

### atomic_write mit tmp + fs.move (journal.lua)
- `fs.move` in CC:Tweaked nach Delete/Create nicht zuverlässig → CORRUPT
- Fix: Direkt in Zieldatei schreiben

### GitHub API für SHA-Auflösung
- Rate-Limit 60/h ohne Token → schlägt bei mehreren Computern fehl
- Fix: Direkt `"beta"` als Ref verwenden

### navigate_and_redraw in ui_router
- Funktion existierte nicht → handle_input brach silent ab → kein Seitenwechsel
- Fix: Direkt `self:prev()` / `self:next()` aufrufen mit nav_debounced

### footer/list_controls auf nil setzen bei Transition
- Führt dazu dass Touch-Zonen nach Transition fehlen
- Fix: Nur bei echtem Monitor-/Seitenwechsel nil setzen, nie vorher

### Agent-Audit-PRs blind mergen
- PRs #503-#513 (August 2026) wurden ohne ausreichende Verifikation gemergt,
  viele hatten Abhängigkeiten auf nicht-existente Funktionen
- Fix: Jeden PR einzeln verifizieren (Syntax → Manifest-Resync → volle
  Testsuite → alle `tests/*_test.py`) bevor gemergt wird — seitdem
  Standardablauf für jeden PR in diesem Repo

## Wichtige Regeln

- **NIEMALS** Dateien manuell per curl/Server-Konsole anlegen — immer über den Installer
- Manuell angelegte Dateien → root-Ownership → Berechtigungsprobleme
- Installer-Update: `wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer`
- Vor dem Mergen von Agent-generierten PRs: einzeln verifizieren (siehe oben)

## Backlog — mögliches zukünftiges Feature (nicht priorisiert)

- **Unabhängiger "Wächter"-Mechanismus für RT-Node-Ausfall:** Stürzt
  ausgerechnet der RT-Computer selbst ab (Server läuft normal weiter), läuft
  der Reaktor bis zum automatischen Reboot unbeaufsichtigt auf dem letzten
  Stand weiter. Bewusst zurückgestellt: Risiko eingeschätzt als unkritisch.
  Falls gewünscht: ein zweiter, unabhängiger Node könnte bei
  Kommunikationsausfall eines RT-Nodes proaktiv eingreifen (analog zu
  VALVE's `tick_failsafe`).
- **Positionsabhängige Stau-Diagnose:** mit den HOP_SCAN-Daten aus PR #550
  ließe sich künftig auch erkennen, WO genau eine Lieferung hängt (nicht
  nur, dass der Timeout überschritten wurde) — siehe Diskussion vom
  2026-09-07, noch nicht umgesetzt.

## Doku-Index
- `docs/README.md` — vollständiger Dokumentationsindex
- `docs/CI_MAINTENANCE.md` — CI-Bugs und Fixes
- `docs/SESSION_HANDOFF.md` — dieser Handoff
- `docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md` — historischer
  Gesamt-Audit, wird von ~30 Testdateien referenziert
