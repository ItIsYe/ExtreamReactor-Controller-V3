# Session Handoff — XReactor Controller V3

**Stand: 2026-10-13 | beta | manifest-v823 | HEAD `a19dd78a`**

---

# Übergabe Sitzung 2026-10-04 — RT-Durchgang, Anlagentest, Selbstheilung

**Startinfo für eine neue Sitzung.** Alles darunter ist älterer Bestand und
weiterhin gültig, aber nicht Gegenstand dieser Sitzung.

## Stand bei Übergabe

| | |
|---|---|
| Branches | auf GitHub nur noch `beta` (Arbeitsstand) und `main` (wenn alles läuft); alle anderen am 2026-10-04 gelöscht |
| HEAD | `a19dd78a` |
| Fassung | `manifest-v823` / `beta-v823`, Prüfsumme `8f7c66a7` (aus `xreactor/release.lua`, nicht gezählt) |
| Tests | 414 Lua + 45 Python, grün |
| Arbeitsbaum | sauber, nichts Unverbuchtes |
| Sprache | Oberfläche, Kommentare und Commit-Texte **deutsch** |
| Ablauf | direkt auf `beta` committen und pushen, **kein PR** (Betreiberentscheidung 2026-10-04) |

### ⚠️ Stehende Vorgaben des Betreibers, am Sitzungsende noch in Kraft

> „achtung nichts umsetzen nur prüfen und iden konzept geben"

> „gehe wie eben auch vorsichtig vor und wenn es sinnvoll ist, Codeblöcke
> oder Dateien neu zu schreiben als drin rumzudoktern, mach das. **Das gilt
> ab jetzt auch immer so.**" (2026-10-12)

Heißt: freigegebene Arbeit vorsichtig umsetzen; wo ein Block oder eine
Datei durch Flicken unübersichtlicher würde, ihn ganz neu schreiben (so in
v815 `monitor_ui.build_turbine_status` und `master/ui/updates.lua`).

Seither wird nur umgesetzt, was der Betreiber **einzeln freigibt**.
Freigegeben und umgesetzt (Folgesitzungen 2026-10-04/05): der Chunk-Test,
der Schleifen-Fix (v812), die CI-Remote-Prüfung und derselbe Fix für MASTERs
Schleife (v813, ohne die Heartbeat-Logik anzufassen). Am 2026-10-08:
**„Ok der Code der noch offen zu fixen ist machen"** — umgesetzt in v814
(siehe A und F), dazu drei Entscheidungen (F). Am 2026-10-12: **„mach die
Punkte aus 2. Aber vorsichtig, und wenn es mehr Sinn macht, Blöcke komplett
neu zu schreiben, als drin rumzudoktern, mache das"** — umgesetzt in v815
(siehe G). Ebenfalls am 2026-10-12: **„Mach Punkt 2 und streich Punkt 4"**
— FUEL-Routen auf globale Reaktor-Kennung, umgesetzt in v816 (siehe H);
MASTER-Ausfall-Befunde A/B und die P2-Liste des Audits gestrichen. Danach:
**„Mach den Rest von Stufe 1"** — Selbstheilung Ebene 1, umgesetzt in v817
(siehe I). Ebene 2 und 3 der Selbstheilung (B) sind NICHT freigegeben. Alles
andere braucht weiter eine ausdrückliche Freigabe, bevor Code angefasst wird. Der Betreiber kann derzeit **nicht im Spiel testen**
(„Bau weiter dran ich kan gead keine tests machen").

## Was in dieser Sitzung gemacht wurde (11 Commits, `670bb1c0` … `f331e450`)

### 1. RT-Durchgang von oben bis unten, alle P1-Befunde behoben

- **Schreiblast.** Spulen-Dirty-Check in `rt2_adapter.apply_turbine`
  (`coil_known` aus `turbine_info.features.coils`): gemessen 7,00 → 0,00
  Schreibzugriffe/Tick; Durchfluss 21,00 → 0,10 bei 20 Turbinen.
  Stab-Schreibzugriffe bewusst zurück auf 1/Tick (siehe Rücknahme unten).
- **Uhrsprung.** `rt2_master_link`: `age_ms < 0` gilt als *nicht verbunden*
  statt als frisch.
- **MASTER-Schwelle.** `health_payload`: `DEFAULT_PEER_TIMEOUT_S = 20.0`,
  `master_peer_state` nimmt den **frischesten** MASTER-Nachbarn,
  Zeitstempel aus der Zukunft werden verworfen, `nil` heißt *nicht
  verbunden*. `main.lua` übergibt `master_seen` ohne `or os.epoch`.
- **Stabrate.** `rt2_reactor`: `MAX_STEP = 2`, `MIN_ADJUST_INTERVAL_MS = 1000`
  → 12 %/s auf 2 %/s. Messtabelle steht im Kommentar. `ROD_MIN = 70`
  unverändert.
- **Durchflussgrenze je Turbine.** `adapters/turbine.lua`:
  `MAX_FLOW_METHODS = { "getFluidFlowRateMaxMax" }`, `flow_limit` →
  `read_turbine().max_flow`. `FLOW_METHODS` auf `{ "getFluidFlowRateMax" }`
  verkürzt; `setTurbineFlow` setzt jetzt `setFluidFlowRateMax` zuerst und
  verändert `caps` nicht mehr.
- **Spule.** Notfreigabe greift schon unter 95 % der Zieldrehzahl; das
  Einlernen terminiert wieder (Mindest-Verbesserung für die Stabilitätsuhr).
- **RT-Konfigschema v8.** Auslöse-Stichproben 3 → 10 mit Migration
  (`RT_CONFIG_VERSION_TRIP_SAMPLES_MIGRATION`, `LEGACY_TRIP_SAMPLES = 3`).

### 2. FUEL: „lädt die eingestellten Routen nicht" — Ursache war die Anzeige

Die Routen **waren** geladen. Der Schirm sagte „Keine Reaktoren
konfiguriert", weil `ui_completion` die *betriebsbereite* Liste gezählt hat.
Vier bisher stumme Zustände sind jetzt unterscheidbar:
`CONFIG_REQUIRED` (über `configured_reactor_count`), `NO_EXPORT_CHEST`,
`REACTOR_ID_UNKNOWN`, und `config_normalizer` setzt
`lg.disabled_reason = "EXPORT_CHEST_MISSING"`, wenn es die Logistik
zwangsabschaltet. Neu: `fuel_status_network.known_reactor_count(cache)`.
`logistics_router.refresh_peripherals()` (`:426`) wickelt Bridge und
Export-Kiste alle `discovery_interval` (60 s) neu ein (`:1199-1202`).

### 3. Gesamtanlagen-Test (Betreiberentscheidung: „Erst Gesamtanlagen-Test bauen")

Neue Prüfstände: `tests/support/cc_node_boot.lua` (bootet eine echte Rolle
auf einem virtuellen CC-Dateisystem), `tests/support/node_message_bus.lua`
(trägt `modem.transmit` an alle anderen Knoten),
`tests/support/plant_nodes.lua` (`new_rt` mit `reactor_aliases`/`reactor_list`,
`new_master`, `new_fuel`, `new_energy`, `new_reprocessor`, `new_valve`,
`boot_all`).

Die echte Topologie des Betreibers ist damit nachgefahren: **8 RT, 1 MASTER,
1 FUEL, 1 REPROCESSOR, 4 ENERGY, ~10 VALVE = 25 Knoten, 16 benannte
Reaktoren** (zwei je RT-Knoten, „Reaktor 1" bis „Reaktor 16"). Ergebnis:
0 verworfene und 0 abgelehnte Nachrichten, kein WARN/ERROR, die
Leistungsaufteilung anteilig wie entworfen, beide Reaktoren je Knoten
geregelt, und die Namen kommen bis FUEL durch — vom Betreiber im Betrieb
bestätigt („am fuel schirm kommen die namen an wie ich die raktoren bei rt
node benant habe").

## ⛔ Zurückgenommen — nicht wieder einbauen

**Der Stab-Dirty-Check (`26ee86b8`, aus v808).** `control_rod_level` ist der
**Mittelwert** über alle Stäbe. Der Mittelwert kann dem Ziel entsprechen,
während kein einzelner Stab dort steht — der Check hat ungleiche Stäbe
festgefroren. Im Betrieb gemeldet als „eine rt node spint rum". Das
unbedingte Schreiben je Tick **ist** die Selbstheilung für ungleiche Stäbe.
Der Spulen-Check bleibt, der ist über `features.coils` abgesichert.

## Offene Befunde — geprüft, Konzept vorhanden, nichts umgesetzt

### A) Chunk-Entladen: Ursache gefunden, behoben in v812 (Hauptbefund)

Meldung: RT-Knoten erholen sich nicht, wenn Chunks nicht geladen waren;
erst ein Neustart des RT-Knotens half. Präzisierung des Betreibers:
**hauptsächlich die RT-Node — nach deren Neustart liefen MASTER und FUEL von
selbst wieder.** Dazu: „es waren noch lebende Werte aber nur rpm".

**Ursache, am echten Code nachgewiesen: ein verlorenes Timer-Ereignis legt
eine Lauf-Schleife für immer still.** Beide Schleifen in
`nodes/support/runtime.lua` warteten auf genau EINEN Timer: die schnelle
brach nur bei genau ihrem Timer aus der Warteschleife aus, die langsame rief
`os.sleep()`, das in CC:Tweaked (`bios.lua:50-56`) ebenfalls nur auf diesen
einen Timer wartet. CC:Tweaked verwirft Ereignisse, sobald 256 in der
Warteschlange stehen (`ComputerExecutor.QUEUE_LIMIT`), Timer eingeschlossen
— beides am CC:Tweaked-Quelltext (1.20 und 1.21) geprüft.

| Schleife | trägt | nach einem verlorenen Timer (bis v811) |
|---|---|---|
| langsam | Discovery, Telemetrie | Status an MASTER bleibt aus → MASTER und FUEL ohne Daten |
| schnell, periodischer Takt | **Regelung** | tot; Comms und Schirm laufen auf Ereignissen weiter → **lebende Drehzahlen am Schirm** |

Mit den echten Schleifen und dem originalen `os.sleep` nachgefahren: 19
Takte, dann keiner mehr, obwohl ständig andere Timer und Funknachrichten
eintreffen. Auf der RT-Node schlägt das zuerst zu, weil dort beim
Chunk-Laden mit Abstand die meisten Peripherie-Ereignisse einprasseln.
**Nicht gemessen** ist, ob die Warteschlange im Spiel wirklich überläuft.

Betreiberbeobachtung (2026-10-05, aus der Zeit vor v812): **„der Regler war
eingefroren, aber die Live-RPM-Werte wurden weiter gelesen und angezeigt".**
Genau das Bild der schnellen Schleife ohne Timer: der Schirmdienst zeichnet
auch auf eingehende Funknachrichten neu (`services/ui_service.lua`,
`due`-Prüfung gilt auch für `modem_message`) und liest dabei die Turbinen
frisch, die Regelung tickt nur im periodischen Takt. Das einzige andere
Bild dieser Art im Code ist ein hängender Update-Quiesce — der stellt aber
Durchfluss 0, Spule ein, Stäbe 100 und endet nach 60 s im erzwungenen
Update.

**Behoben in v812** (`wait_cycle`, seit v814 `make_timer_guard`): weiter, wenn der eigene Timer kommt ODER
wenn bei irgendeinem Ereignis Intervall + 1 s verstrichen sind (`os.clock`,
in CC:Tweaked Servertakte — dieselbe Zeitbasis wie `os.startTimer`,
monoton). Ein verlorener Timer kostet gut eine Sekunde. Gilt für RT, FUEL,
WATER, REPROCESSOR und VALVE. Test: `tests/runtime_lost_timer_test.lua`.

**Im Betrieb prüfen:** nach dem nächsten Chunk-Laden die RT-Diagnoseseite
ansehen, Zeile **„TIMER LOST / LATE"**. Eine Zahl über 0 bei LOST belegt die
Ursache — die Node lief diesmal weiter. Im Status steht dann der Grund
`TIMER_LOST` (ohne Herabstufen); MASTER protokolliert die Änderung („Node …
reasons … -> TIMER_LOST"), zeigt Gründe aber auf keinem Schirm (bekannte
Lücke, `master/ui_controller.lua:620`). Hängt die RT-Node trotzdem wieder
und LOST bleibt 0, ist es eine andere Ursache.

**MASTER: dasselbe Muster, behoben in v813.** Betreiberbeobachtung
2026-10-05 mit v812: **„master schirm ändert sich nur beim antippen"**, alle
RT-Knoten zeigten MASTER DOWN, obwohl MASTER lief, und alle Knoten reagierten
nur noch verzögert auf Änderungen. `master/loop.lua` wartete auf genau einen
0,5-s-Timer; nur in diesem Takt laufen Heartbeat, Status, Befehle an die
Knoten und das Neuzeichnen. Funknachrichten nahm die Schleife weiter an, und
eine Berührung löste einen Ereignis-Takt aus — daher das Bild. Jetzt derselbe
Taktgeber wie in den Knoten (`runtime.make_cycle_waiter`, den auch die beiden
Knoten-Schleifen nutzen). **Die Heartbeat-Logik selbst (Telemetrie-Dienst,
Intervalle, Peer-Timeouts) ist bewusst unverändert** — Betreiberwunsch.
Sichtbar wird ein Ausgleich auf MASTERs Terminal als Zeile „[MASTER]
Takt-Timer ausgeblieben (N mal seit Start) …" (höchstens einmal je Minute)
und als WARN im Log; Zähler in `loop_stats().master`. Test:
`tests/master_loop_lost_timer_test.lua` (echte Schleife; der alte Stand
bleibt nach einem verlorenen Timer bei 9 Takten stehen).

Zum „langsam" nach Updates gehört außerdem: jedes Update startet alle Knoten
neu, und RT lernt nach jedem Neustart neu
(`rt2_orchestrator.new_output_state`: `learning = true`, nicht persistiert).
Während des Lernens überstimmt RT MASTERs Vorgabe (Betreiberentscheidung
2026-09-28). v812 selbst kostet messbar nichts (0,62 µs je Funknachricht).

**Dasselbe Muster überall sonst: behoben in v814.** Der Kern ist jetzt
`runtime.make_timer_guard` (ein Timer, dessen Ablauf die Schleife auch ohne
sein Ereignis erkennt); `make_cycle_waiter` baut darauf auf.

| Stelle | Folge bis v813 | Test |
|---|---|---|
| ENERGY Matrix-Thread (`os.sleep`) | Speicherwerte an MASTER eingefroren | `energy_lost_timer_test.lua` |
| ENERGY Heartbeat-Thread (zwei Timer) | Dienste-Timer weg: Telemetrie/Discovery/Schirm/Quiesce standen; Heartbeat-Timer weg: Heartbeat nur noch aus Funkverkehr | dto. |
| Auto-Updater (`make_loop`) | keine Update-Prüfung mehr bis zum Neustart | `auto_update_lost_timer_test.lua` |
| jedes `os.sleep()` (Installer, Quiesce-Warten, Wiederholungen) | Haenger mitten im Update, Knoten mit gestoppter Laufzeit | `sleep_guard_test.lua` |
| Log-Collector Hauptschleife | Ping/Flush standen, Knoten hielten ihn für offline | `log_collector_lost_timer_test.lua` |
| Crash-Schirme (`runtime.lua`, MASTER-Rückfall, Log-Collector) | kein automatischer Neustart | — |
| `run_event_loop` (ungenutzt) | — | bestehende Tests |

`core/sleep_guard.lua` setzt `start.lua` als Allererstes für den ganzen
Rechner ein: `os.sleep(n)` kehrt zurück, wenn der eigene Timer kommt ODER
bei irgendeinem Ereignis n + 1 s vergangen sind. Bewusst ohne Filter auf
„timer": nach einem Quiesce laufen kaum noch Timer, Funkverkehr aber
schon. Die Heartbeat-**Logik** (wann gesendet wird) ist unverändert, nur
das Warten auf den Timer.

**Die erste Zuordnung (Fähigkeiten-Cache) hält nicht.** Der Cache in
`nodes/rt/turbine_control.lua` wird zwar einmal geschrieben und nie erneuert
(`:57-58`, `:105`, `discovery_runtime.lua:35-49`), liegt aber nicht im
Regelpfad: `rt2_engine.tick` und der Status lesen über `adapters/turbine.lua`
und `adapters/reactor.lua` (`rt2_engine.lua:150`, `:162`;
`status_snapshot.lua:40`, `:75`), und die heilen selbst.
`tests/plant_chunk_reload_test.lua` zeigt in fünf Chunk-Lagen (Turbine weg
und verkürzt zurück; ganze Anlage weg; weg und verkürzt zurück = Bild „nur
RPM"; jeder Aufruf wirft; Ausfall über die Schonfrist) die Erholung ohne
Neustart. Was der veraltete Cache bricht, ist der **Update-Quiesce**: für
die Turbine nie bestätigt, nach 60 s erzwingt `auto_update.lua:217-222` das
Update. **Behoben in v814:** der Quiesce läuft namensbasiert über
`adapters/turbine.lua` (neu: `method_set`) und `adapters/reactor.lua`,
je Turbine wie vorher drei Stellbefehle und drei Rückmessungen (bei 50
Turbinen je Knoten zählt jeder Aufruf). Test:
`tests/rt_update_quiesce_after_chunk_reload_test.lua` (echte RT+MASTER,
Anlage weg → verkürzt zurück → voll zurück; der alte Stand bestätigt nie).
Der Harness-Reaktor kennt kein `getControlRodsLevels`; ohne VOLLSTÄNDIGE
Stabrückmessung bestätigt der Adapter „voll eingefahren" absichtlich nicht
— der Test ergänzt die Methode wie bei Extreme Reactors. Cache und
wrap-Handles bleiben für den Lese-Rückfall des lokalen Schirms bestehen.

**B3** (Monitor-Handle): bestätigt und **behoben in v814**. RT löste den
Monitor nur einmal in `init()` auf; fehlte er beim Start, blieb der Schirm
bis zum Neustart auf dem Terminal. Jetzt `resolve_monitor()` bei jeder
Discovery, mit der eingestellten Skala. Test:
`tests/rt_monitor_late_attach_test.lua`.

### B) Selbstheilung — Konzept in drei Ebenen (letzte Antwort der Sitzung)

1. **Abgeleiteter Zustand darf nie dauerhaft sein.** Negative Ergebnisse
   verfallen mit Zeitstempel, positive bleiben. Beweisgetriebene Verwerfung:
   gelingt ein Aufruf, den der Cache für unmöglich hält, fliegt der Eintrag.
   `getMethods`-Fehlschlag von „keine Methoden" trennen.
   `warn_once`/`shouted` zurücksetzbar machen, sonst ist die *nächste*
   Störung stumm. Vorbild: `adapters/turbine.lua:176-195`. Risiko niedrig.
   **Diese Ebene behebt den Update-Quiesce, nicht das Feldbild** (siehe A).
   **Erledigt mit v814–v817** (siehe I).
2. **Ein Selbstprüf-Dienst, der nach der Wirkung fragt**, nicht nach der
   Anwesenheit: „habe ich für jedes gebundene Gerät einen frischen Messwert,
   und habe ich in den letzten N Sekunden überhaupt etwas gestellt?"
   Reaktion gestaffelt: abgeleiteten Zustand verwerfen → Discovery erzwingen
   (inkl. Rücknahme der Slow-Scan-Drosselung, die heute auf 60 s streckt) →
   melden. Vorbilder im Haus: `rt2_safety.track_availability`
   (`ever_valid` + `missing_ticks`) und `valve/controller.lua:346`
   `tick_failsafe`. **Diese Ebene hätte geholfen, ohne die Ursache zu kennen.**
3. **Geordneter Selbst-Neustart, letzte Stufe.** Über
   `core/update_handshake.lua` (`request_quiesce` → sichere Ausgänge Stäbe
   100 / Durchfluss 0 → `wait_for_runtime_stopped` → Neustart) — denselben
   Weg nimmt `auto_update` schon. Bedingungen: **persistiert begrenzt**
   (höchstens 1 Neustart/30 min, 3/h, danach Stillstand mit Alarm — ohne
   Persistenz überlebt die Grenze den Neustart nicht), vorher an MASTER
   melden und dauerhaft protokollieren, **standardmäßig AUS**.

Quer darüber: **Heilung muss sichtbar sein.** Zähler im Statuspayload
(Selbstheilungen seit Boot, letzter Grund, letzter Zeitpunkt). Ein Knoten,
der sich alle zehn Minuten heilt, ist nicht gesund, sieht aber ohne Zähler
genau so aus wie einer, der läuft. Ein erster Baustein steht seit v812:
`runtime.loop_stats()` und die Zeile „TIMER LOST / LATE" (siehe A).

Stolperstelle dabei gefunden: `startup_watchdog_s = 60` steht in
`nodes/rt/config.lua:52` und wird vom Normalizer validiert
(`config_normalizer.lua:196-199`), **ausgewertet wird er nirgends** —
`main.lua:419` setzt `startup_watchdog_tripped = false` fest. Der Platz ist
belegt, die Wirkung fehlt. **Geklärt 2026-10-08:** ein Rest des
v1-Reglers — die Startsequenz mit Timeout ist mit `6f762364` (2026-06-22,
SCADA-Umbau) entfallen. Bewusst nicht nachgebaut: das wäre neues
Verhalten (Ebene 2), keine Reparatur. Ebenfalls auffällig:
`service_manager.lua:65` `schedule_retry` wiederholt mit Backoff, verwirft
dabei aber **nie** das Handle oder den abgeleiteten Zustand, an dem es
scheitert. **Seit v815** gibt es dafür einen Haken (siehe G) — wirksam nur
für Dienste, die `discard_derived_state` anbieten (bisher `MATRIX_SAMPLE`).

**Reihenfolge: Betrieb beobachten (TIMER LOST, siehe A) → Ebene 1 (erledigt,
v817) → Ebene 2 → Ebene 3.** Das Chunk-Modell steht
(`tests/plant_chunk_reload_test.lua`); jede Ebene wird dort nachgewiesen.

### C) Grenzen der Harness (Konzeptpunkt A)

Modelliert sind: Peripherie *da / weg / verkürzte Methodenliste*,
„angemeldet, aber jeder Aufruf wirft", und veraltete `wrap`-Handles beim
Wieder-Anmelden (der Stub-`wrap` liefert den Methodentisch zum Zeitpunkt des
Einbindens). **Nicht** modelliert: ob ER2 im Spiel wirklich verkürzte Listen
meldet, Peripherie-Ereignisse (die Discovery läuft nur auf ihrem Takt), das
Entladen des RT-Computers selbst, geteilte Kabelnetze, der lokale Monitor.

Außerdem ersetzt die Harness die Lauf-Schleifen durch Rekorder
(`cc_node_boot.capture_loops`) und tickt die Dienste direkt — Fehler **in**
den Schleifen sieht sie nicht. Genau deshalb blieb der Timer-Befund dort
unsichtbar; dafür gibt es `tests/runtime_lost_timer_test.lua`.

### D) Reaktor-Identität (dokumentiert, Folgearbeit offen)

`core/registry.build_device_id(name, type_name, signature)` =
`TYPE-djb2(name|type|methods)` — **der Aliasname aus `reactor_names.lua`
steckt nicht im Hash**. CC:Tweaked nummeriert Peripherie je Rechner, also
kollidieren kurze Reaktor-Kennungen über RT-Knoten hinweg: 16 globale
Kennungen, aber nur 2 kurze. `master/fuel_relay.lua` veröffentlicht global
plus kurzen Altnamen und **verwirft den Alias bei Kollision**.
Folge: `fuel_routes.lua` muss die **globale** Kennung tragen
(`node_id:local_id`). **Umgesetzt in v816 (siehe H).**

### E) Versionierung

`scripts/manifest_sync.py --write` hebt `manifest_version`/`manifest_id`
**nur**, wenn manifest-geführte Dateien sich ändern; `release.lua` ist als
selbstbezüglich ausgenommen. **Tests und Dokumentation stehen nicht im
Manifest** — Commits, die nur daran rühren, heben die Fassung nicht.
`installer/auto_update.lua:374` aktualisiert bei
`remote_version > local_version`. `commit_sha = "beta"` ist ein gewollter
Platzhalter, `scripts/package_release.py:48` setzt für feste Releases eine
echte SHA.

**Prüfsummen, entschieden 2026-10-08, umgesetzt in v814** (Betreiber: „für
Dateien Prüfsumme, um festzustellen, wie alt die sind und ob die überhaupt
noch relevant sind bzw. noch genommen werden dürfen"):

- `payload_digest` in `manifest.lua` und `release.lua`: CRC32 über Pfad,
  Größe und Hash aller Einträge außer `release.lua` (die trägt ihn).
  `manifest_sync.py --write` pflegt ihn, `--check` prüft ihn. Er steht in
  der Startzeile: `[BOOT] XReactor RT | beta-v814 (Pruefsumme …)`.
- Der Installer schreibt `/xreactor/install_hashes.lua` (Größe und CRC32
  je installierter Datei, ~5 kB) — das Manifest selbst bleibt aus
  Platzgründen nicht auf dem Knoten.
- `core/install_integrity.lua` prüft die installierten Dateien dagegen
  (gleiche Lesart und CRC32 wie die Installationsprüfung, sonst gäbe es
  Endlos-Reparaturen). Der Auto-Updater prüft beim ersten Check nach dem
  Start und dann alle 6 h; weicht etwas ab (verändert, abgeschnitten,
  fehlt), installiert er neu — **höchstens einmal je Fassung in 6 h**,
  gemerkt in `/xreactor_config/install_repair.lua`.
- **Der Zähler entscheidet weiter über Updates.** Absicht: kurz nach einem
  Push liefert GitHubs CDN manchen Knoten noch die alte `release.lua`; mit
  „Prüfsumme ungleich → aktualisieren" würde ein Knoten zurückfallen und
  wieder vor. Der monotone Zähler verhindert das. Die Prüfsumme sagt, ob
  die Dateien auf dem Knoten genau die der Fassung sind.
- Tests: `install_integrity_test.lua` (u. a. CRC32 jeder Repo-Datei gleich
  der des Manifests), `auto_update_integrity_repair_test.lua`,
  `manifest_payload_digest_test.py`.

### F) Entscheidungen des Betreibers am 2026-10-08

1. **„RT immer neu einlernen nach Neustart."** Nichts persistieren; das
   träge Gefühl nach Updates (RT überstimmt MASTER, solange sie lernt)
   bleibt bewusst.
2. **„Wie viele Turbinen da sind, muss immer durch einen Scan ermittelt
   werden, es gibt keine feste Zahl. Aktuell sind es pro RT-Node 50, das
   kann aber auch unterschiedlich sein."** Im Code gibt es keine
   Obergrenze (`nodes/rt/config.lua`: nachgemessen bis 100). **Gefundener
   Fehler, behoben in v814:** die Touch-Skalierung (`on_scale_change`)
   schrieb die ganze Config samt dem von der Discovery eingetragenen
   Gerätestand nach `rt.lua` — beim nächsten Start galt er als feste Liste
   (`binding.lua`: „explicit"), neue oder nach einem Modem-Reconnect
   umbenannte Turbinen wurden still nicht gebunden. Jetzt wird nur
   geschrieben, was beim Start dort stand; **Config-Schema v9 leert solche
   Listen einmal** und meldet das auf dem RT-Schirm (eine nach v9 von Hand
   gesetzte Liste bleibt). Test: `tests/rt_turbine_count_from_scan_test.lua`
   (50 Turbinen, Skala ändern, Neustart mit 52 → alle 52 gebunden).
3. **Prüfsummen für Dateien** — siehe E.

### G) Umgesetzt am 2026-10-12 (v815)

Freigabe: „mach die Punkte aus 2" — die vier kleinen Code-Reste aus der
Liste vom 2026-10-12. Jeder hat einen Test, der am Stand v814 aus dem
richtigen Grund scheitert.

1. **RT-Schirm: ein Leseweg.** `monitor_ui.build_turbine_status` las eine
   Turbine, für die `adapters/turbine.inspect()` keine Drehzahl oder keinen
   Durchfluss lieferte, ein zweites Mal — per `peripheral.wrap` und mit dem
   Fähigkeiten-Cache der Discovery (`ctx.capability_cache`, wird je Name
   einmal geschrieben und nie erneuert). Neu geschrieben: nur noch
   `inspect()`, nicht Lesbares bleibt unbekannt (`nil` → „-"). Damit zeigt
   der Schirm, was der Regler sieht, statt bei blindem Regler normal
   auszusehen (vgl. `rt2_unreadable_turbine_write_test.lua`). Entfallen:
   `turbine_control.read_turbine_rpm/read_turbine_flow` und ihre
   Durchreichungen in `main.lua`/`status_snapshot.lua`.
   Test: `tests/rt_monitor_single_read_path_test.lua`.
   `ctx.capability_cache` und `module.caps`/`module.peripheral` wurden
   danach nur noch geschrieben — mit v817 entfernt (siehe I).
2. **ENERGY: unbekannte Matrix-Kapazität ist nicht „100 % voll".**
   `matrix_snapshot_runtime.rebuild_snapshot` setzte `capacity = stored`,
   solange `getCapacity` nie gelesen war. Folgen, nachgemessen: MASTER
   meldete `MATRIX_NEAR_FULL … 100.0%` für eine Matrix, deren Füllstand
   niemand kannte, und die Gesamtanzeigen rechneten den erfundenen Nenner
   mit. Den **Lastabwurf** hat es nicht ausgelöst: ohne vollständige Probe
   ist der Schnappschuss veraltet, und `runtime_ops_profile.lua` lässt
   veraltete ENERGY-Knoten aus. Jetzt wie bei den Speichern
   (`storage_snapshot_runtime.lua`): Zähler und Nenner nur gemeinsam,
   `capacity_known`, `total.stored_all`, `total.capacity_unknown`;
   ENERGY- und MASTER-Seite zeigen „n/a".
   Test: `tests/energy_matrix_unknown_capacity_test.lua`.
3. **`service_manager`: abgeleiteten Zustand verwerfen.** Der Manager hält
   selbst keine Handles. Er fragt deshalb den Dienst: wer
   `discard_derived_state(stage, err, n)` anbietet, bekommt nach je 3
   Fehlschlägen von `tick()` in Folge die Gelegenheit (`discard_after_failures`,
   0 schaltet ab). `init()` wird bewusst **nicht** neu gestartet —
   `comms_service:init()` baut Netzwerk und Comms-Objekt neu, auf die
   andere Teile Verweise halten. Erster Nutzer: `MATRIX_SAMPLE`
   (`runtime:invalidate()`, dieselbe, die die ENERGY-Discovery bei
   Topologie-Änderung ruft). Nebenbei: die Fehlerzeile hatte Stufe und
   Name vertauscht. Zähler `total_failures`/`discards` stehen in
   `manager.service_state`. Test:
   `tests/service_manager_discard_derived_state_test.lua`.
4. **Dateiprüfung auf MASTERs Seite „Updates".** Spalte DATEIEN je Knoten
   („OK", „3 ABW", „-" ohne Liste, „?" noch nicht geprüft oder Ergebnis zu
   einer anderen Fassung); abweichende Dateien zählen als „braucht
   Aufmerksamkeit" (Status DATEIEN). MASTERs eigenes Ergebnis in der
   Fußzeile. **Transport über das STATUS-Paket** (`shared/build_info.lua`
   → `meta.build.integrity`), **nicht über den Heartbeat** — der Test hält
   fest, dass der Heartbeat nur `state` und `manifest_version` trägt.
   Geprüft wird beim ersten Update-Check nach dem Start, vorher steht „?".
   Test: `tests/master_updates_integrity_test.lua`.

Beifang: `alert_rules_matrix_missing_offline_suppression_test.lua` und
`alert_rules_stale_recovery_suppression_test.lua` gaben die Rolle als
`'ENERGY_NODE'` an — die Konstante ist `"ENERGY-NODE"`, die ENERGY-Regeln
liefen dort also gar nicht, beide Tests bestanden immer. Jetzt mit der
Konstante; ein Gegenversuch (Unterdrückung entfernt) lässt den Test
scheitern.

### H) Umgesetzt am 2026-10-12 (v816): FUEL-Routen auf globale Kennung

Lage vorher: neu eingelernte Routen trugen die globale Kennung schon
(`reactor_targets.lua` nimmt `global_reactor_id`). Ältere Routen mit
**kurzer** Kennung funktionierten nur, solange diese anlagenweit eindeutig
war — MASTER (`fuel_relay.lua`) und das Mithören (`fuel_status_network.lua`)
verwerfen den kurzen Alias bei einer Kollision. Bei 16 Reaktoren und 2
kurzen Kennungen hieß das: keine Füllstände, keine Lieferung, keine Meldung.

Neu: `nodes/fuel/route_identity.lua` und ein Hintergrunddienst
`route_id_upgrade` in `nodes/fuel/main.lua` (alle 30 s):

- umgestellt wird nur, wenn der **Routen-Name** unter den Reaktoren mit
  dieser kurzen Kennung **genau einen** trifft (Groß/klein egal). Die
  Kennung allein reicht nicht — „gerade eindeutig" kann heißen, dass der
  andere RT-Knoten kurz schweigt.
- nicht umgestellt, sondern einmal gemeldet („… im ROUTER neu einlernen" /
  „… alte Route löschen"): mehrdeutig, falscher Name, ohne Namen, Reaktor
  schon unter globaler Kennung eingelernt. Unbekannte Kennungen (RT aus)
  bleiben still.
- wartet, solange im Router bearbeitet wird (`router_ui:is_editing()`) oder
  eine Lieferung läuft (`logistics_router:is_delivering()`).
- schreibt über denselben atomaren Weg wie SPEICHERN
  (`router_ui.save_routes`), **erst die Datei, dann die Laufzeit-Config**;
  scheitert das Schreiben, bleibt beides und es folgt 10 min Pause. Die
  Abklingzeit seit der letzten Lieferung zieht mit um
  (`logistics_router:rekey_reactor`).
- Beifang: `router_ui.copy_reactor` verlor das alte Feld `reactor_port` —
  SPEICHERN lehnte dann die ganze Liste ab.

Test: `tests/fuel_route_global_id_upgrade_test.lua` — Regeln, Schreibweg
und Ende zu Ende mit zwei echt gebooteten RT-Knoten gleicher kurzer
Kennung, MASTER und FUEL: die alte Route steht danach mit globaler Kennung
in `fuel_routes.lua`, FUEL kennt den Füllstand des **richtigen** Reaktors,
die nicht zuordenbare Route ist gemeldet. Am Stand v815 scheitert er an der
Umstellung.

### I) Umgesetzt am 2026-10-12 (v817): Selbstheilung Ebene 1

Freigabe: „Mach den Rest von Stufe 1". Ebene 1 heißt: abgeleiteter Zustand
darf nie dauerhaft sein (siehe B). Vorher erledigt: Turbinen-Adapter merkt
sich unvollständige Methodenlisten nicht (vor v812), Update-Quiesce
namensbasiert (v814), Schirm mit einem Leseweg (v815), Verwerf-Haken im
`service_manager` (v815).

1. **Keine dauerhaften Geräte-Handles mehr im RT.** Die Discovery legte je
   gebundenem Namen ein wrap-Handle (`ctx.peripherals`) und einen
   Fähigkeiten-Eintrag (`ctx.capability_cache`) an und erneuerte beide nie.
   Beides ist raus, samt `module.caps`/`module.peripheral`,
   `get_device_caps`, `build_capabilities`, `clamp_turbine_flow`,
   `has_reactor_rod_write_path` (kein Leser). `discovery_runtime.cache()`
   heißt jetzt `normalize_bindings()` und prüft nur noch die Namen nach
   Geräteart. Einziger verbliebener Leser war die Dampfmessung ohne
   externen Tank (`reactor_control.read_reactor_steam_amount`) — die liest
   jetzt jeden Reaktor frisch ein; dem alten Handle fehlte nach halbem
   Laden `getHotFluidAmount` für immer. Test:
   `tests/rt_reactor_steam_fresh_read_test.lua`; umgeschrieben:
   `rt_peripherals_devices_isolation_test.lua`, `rt_discovery_runtime_test.lua`;
   entfallen mit ihren Funktionen: `rt_get_device_caps_kind_normalization_test.lua`,
   `rt_capability_cache_targeted_invalidation_test.lua`.
2. **Warnungen einmal je Störung.** `core/once_log.lua` (neu): gemeldet wird
   beim Eintritt; ein erfolgreicher Aufruf meldet die Erholung, die nächste
   Störung wird wieder gemeldet — höchstens einmal je Minute (Flattern).
   Umgestellt: `adapters/turbine.lua` (Aufrufe, Typfehler, Fähigkeiten,
   Schirm-Meldungen), `reactor.lua` (Aufrufe, Typfehler, Stäbe lesen und
   stellen getrennt, `setActive`), `energy_storage.lua`,
   `induction_matrix.lua`, `logistical_sorter.lua` (getMethods),
   `monitor.lua` (Einbinden, Aufrufe). Hinweise zur Konfiguration bleiben
   einmalig. Eine dauerhaft fehlende Methode ist **eine** Störung, kein
   Minutentakt. Test: `tests/once_log_rearm_test.lua`.
3. **Geprüft, nichts zu tun:** der Reaktor-Adapter fragt die Methodenliste
   je Aufruf frisch; ENERGY prüft die Matrix-Topologie spätestens alle 5 min
   neu (`matrix_topology_cache.forced_rescan_interval_s`); WATER bindet die
   Tanks bei jeder Discovery (15 s) neu ein.

### J) Umgesetzt am 2026-10-12 (v818): Ventil-Erreichbarkeit live

Anlass: Test im Spiel — „die Valves verbinden sich anscheinend nicht mit
FUEL über Funk". Funk und Pairing waren in Ordnung (VALVE `node-68` an FUEL
`node-64` gepaart, MASTER online), FUEL zeigte trotzdem
„Ventil-Verbindung nicht bereit — offline=17" und blockierte alles.
Freigabe: „Ja mach Fehler 1, vorsichtig wie immer".

1. **Ursache (Fehler 1):** `nodes/fuel/redstone_router.lua` legte in
   `refresh()` eine Momentaufnahme an (`_state.integrators`): schaltbar war
   nur, was in genau diesem Augenblick in der Peer-Tabelle stand.
   `refresh()` läuft beim Start — bevor ein VALVE-Node seinen ersten
   Heartbeat geschickt hat — und danach höchstens alle 60 s (nur mit
   eingeschalteter Logistik, nie während einer Lieferung). Bis dahin galten
   alle Ventile als offline, jede Lieferung scheiterte sofort mit
   Safety-Latch. Im Anlagentest: erste Lieferung nach **65,7 s**, jetzt nach
   **5,7 s**.
2. **Jetzt:** `_valve_link()` fragt die Peer-Tabelle in dem Moment, in dem
   die Antwort gebraucht wird: `online`, `stale`, `offline` (war da, ist
   weg — auch nach Ablauf aus der Peer-Tabelle), `waiting` (noch nie
   gehört, FUEL läuft < 60 s), `unknown` (unter dieser Kennung hat sich seit
   dem Start **nie** ein VALVE-Node gemeldet). Senderegel: **BLOCKED** an
   jedes Ventil, das comms führt (auch stale/down — Sperren ist immer
   sicher), **OPEN** nur an ein gerade `online`-Ventil (dieselbe Bedingung
   wie die Exportfreigabe). Nicht gesendet → sofort gescheitert, wie bisher.
   ACK-Pflicht, Safety-Latch, Quiesce: unverändert. Meldungen einmal je
   Störung (`core/once_log.lua`), im Anlauf keine.
3. **Anzeige:** neuer Banner **VALVE_UNKNOWN** „Ventil-Kennung unbekannt —
   N nie gemeldet: <bis zu drei IDs> (+Rest)", Handgriff „ROUTER >
   Ventilkette neu einlernen"; **VALVE_WAITING** „Ventile melden sich noch"
   (LIMITED) im Anlauf; `route_state` `VALVE_UNKNOWN`/`VALVE_WAITING`;
   Diagnosezeile `VALVES n/off/alt/unb`. `VALVE_OFFLINE` heißt jetzt nur
   noch: war da, ist weg oder überfällig.
4. **Harness:** `tests/support/node_message_bus.lua` kann rohe Kanäle
   (`raw_channels`) an alle `wants_events`-Services zustellen, mit dem
   Modem des Empfängers als Seite — damit läuft SET_VALVE/VALVE_ACK im
   Anlagentest echt. Standard unverändert (nur COMMS). Neuer Test
   `tests/fuel_valve_link_live_test.lua` (Router, Anzeige, ganze Anlage mit
   RT, MASTER, FUEL, zwei VALVE-Nodes); scheitert am alten Router aus dem
   richtigen Grund. Hinweis für Harness-Ventile: `redstone_side` und
   `trusted_source` in die Konfig, sonst ACK `applied=false` (kein Aktor)
   bzw. `PAIRING_PERSIST_FAILED` (Test-Platte kann kein `mkdir`).
5. **Noch offen (Betreiber):** ob im Spiel zusätzlich die **Kennungen in
   der Ventilkette** nicht passen (Verdacht, weil offline=17 dauerhaft
   blieb). Mit v818 zeigt der FUEL-Schirm das direkt: steht dort
   „Ventil-Kennung unbekannt", die Ventilkette im ROUTER neu einlernen. Im
   FUEL-Log steht dann je Kennung: „unter der Kennung '…' hat sich seit dem
   Start kein VALVE-Node gemeldet".

### K) Umgesetzt am 2026-10-12 (v819): FUEL-Seite VENTILE

Anlass: nach v818 meldete FUEL im Spiel „6 von 29 noch nicht gehört", die
Zahl änderte sich nicht, die Nodes waren laut Betreiber alle online. Im
Code keine Erklärung gefunden (IDs auf beiden Seiten aus `node_id.txt`,
`update_peer` zählt jede gültige Meldung, Protokoll seit Januar gleich).
Übrig bleiben im Spiel: (1) IDs in der Kette, die keine VALVE-Node hat,
(2) FUEL hört diese Nodes nicht (Reichweite: normale statt Ender-Modem am
FUEL-Computer, oder zwei Modems). Bleibt „melden sich noch" länger als
60 s stehen, startet FUEL neu (Anlaufzeit beginnt von vorn) — noch nicht
geklärt. Wunsch des Betreibers: „ein extra Seite wo nur alle Valves
angezeigt werden … farbig … wann die zuletzt gehört wurden … komplett neue
UI-Seite".

1. **Neue Datei `nodes/fuel/valve_page.lua`**, Seite **4/5** (vor dem
   Router; alle Seitennummern jetzt x/5). Eine Zeile je Ventil, Probleme
   zuerst: ZUSTAND farbig (UNBEKANNT orange, OFFLINE rot, NICHT AKTUELL
   gelb, WARTET grau, ONLINE grün), NAME, ID, ZULETZT (grob: `< 10 s`,
   `vor 20 s`, `vor 3 min`, `nie`), VENTIL (letzte VALVE_ACK: ZU / AUF /
   FEHLER, `?` solange ausstehend), REAKTOREN (in welchen Ketten). Kopf mit
   Zählern, Legende mit Handgriffen, erste Schreibfehler-Meldung eines
   Ventils im Klartext (z. B. „sorter not found …"), 20 Ventile je Seite.
2. **Nur im Bildschirm-Modell, solange die Seite offen ist** — nicht im
   Status-Payload (kein Funkverkehr zu MASTER), kein Neuzeichnen anderer
   Seiten. Grobe Zeitstufen, damit die Seite nicht jede Sekunde neu zeichnet.
3. **`get_valve_status()`** liefert zusätzlich `last_seen_ms` und den Namen
   (bleiben nach Ablauf aus der Peer-Tabelle erhalten), die letzte
   VALVE_ACK als `ack_applied/ack_high/ack_error/ack_ms` und `ack_pending`.
   Achtung Lua: `ack and ack.applied or nil` macht aus `false` still `nil`
   — ausgeschrieben, Test fängt es.
4. Test `tests/fuel_valve_page_test.lua` (Aufbereitung, Zeichnen auf
   82×40 mit echten Farben, Blättern ohne Reste, Router-Felder, Einbindung
   als vierte von fünf Seiten); `fuel_monitor_backbuffer_test` erwartet
   jetzt fünf Seiten.

### L) Umgesetzt am 2026-10-12 (v820): FUEL entlastet — Funkmeldungen gingen verloren

Befund (Betreiber, Seite VENTILE): immer dieselben VALVE-Nodes „nie
gehört", alle mit Ender-Modem → Überlast. Mechanismus: jede Node hört jede
Meldung jeder anderen Node (Rundfunk); CC:Tweaked hat je Rechner höchstens
256 Ereignisse in der Warteschlange und verwirft den Rest still; alle
Rechner teilen sich standardmäßig **einen** Lua-Thread des Servers. Die
Gesamtlast wächst etwa quadratisch mit der Zahl der Nodes.
Hinweis: „nach FUEL-Neustart dieselben IDs" trennt Überlast und Modem
**nicht** sicher — die Sendetakte der Ventile liegen fest zueinander,
unabhängig von FUEL.

1. **`services/ui_service.lua`** (alle Rollen mit Schirm): passive
   Ereignisse prüfen höchstens einmal je Intervall (`last_check`). Vorher
   war die Prüfung nach Ablauf des Intervalls bei **jeder** weiteren
   Funkmeldung erneut fällig — je Meldung ein komplettes Modell samt Kopie
   und Vergleich des ganzen Status. Messung FUEL: 159 → 30 Aufbauten in
   30 s, gezeichnet unverändert 27-mal.
2. **`core/comms.lua` `payload_filter`** (opt-in je Rolle, über
   `comms_service.new{payload_filter=}`): Nachrichten, deren Inhalt die
   Rolle nicht braucht, aktualisieren nur den Absender in der Peer-Tabelle
   (gleiche Umschlagprüfung), keine Nutzlast-Kopie, keine Handler, keine
   Duplikat-Buchführung. Ungültiges und Filterfehler: voller Weg. Ohne
   Filter unverändert. Zähler `metrics.peer_only`.
   `protocol.sanitize_envelope()` = Umschlag ohne Nutzlast.
3. **FUEL** (`fuel_status_network.make_payload_filter`): Inhalt von
   MASTER, von allem mit `dst`, und außer HEARTBEAT/STATUS/HELLO/ALERT;
   sonst nur Absender. Der Füllstand-Mithörer prüft `type`/`role` **vor**
   dem Kopieren (nur RT-Status).
4. **Seite VENTILE, Zeile 5:** `FUEL-LAST: Timer verloren N, verspaetet M`
   aus `runtime.loop_stats()` — N > 0 heißt: Warteschlange lief über.
5. Messung je empfangener Meldung (Host-Lua, Harness 3 RT + MASTER +
   12 Ventile): 0,119 → 0,061 ms. Im Spiel (Cobalt, RT mit 50 Turbinen)
   ist der Gewinn größer. Heartbeat-Logik unverändert.
6. Test `tests/fuel_radio_load_relief_test.lua` (scheitert an jeder alten
   Datei aus dem richtigen Grund).

**Möglicher nächster Schritt (nicht umgesetzt, Freigabe nötig):** denselben
`payload_filter` für die **VALVE-Nodes** (29 Rechner, brauchen von anderen
Nodes nur MASTER und Kommandos) und ggf. weitere Rollen — entlastet den
gemeinsamen Lua-Thread des Servers für alle. Je Rolle vorher prüfen,
welche Handler fremde Status-Inhalte lesen (MASTER braucht alle!).

### M) Funk-Hygiene — Konzept, Stufe 1 (v821), Stufe 2 (v822), Stufe 3 (v823), 2026-10-13

Betreiber: „Funk-Hygiene … alle Meldungen, die nicht nötig sind, raus …
verschiedene Kanäle und Filter, so dass jeder PC nur noch verarbeitet, was
er braucht … erst Konzept, dann vorsichtig." **Server-Konfiguration wird
ausdrücklich NICHT angefasst** (kein `computer_threads`). Freigabe: „Alle
10 s, setze Stufe 1 erst um, dann Stufe 2."

**Befund** (Anlagen-Harness, 11 Nodes, 60 s; Zählskript im Muster von
`tests/radio_hygiene_stage1_test.lua`): 1088 Sendungen/min, jeder Rechner
öffnet 6500/6501/6503 und bekommt damit alles. Außer MASTER braucht keine
Rolle fremde Inhalte (geprüft: on_message von RT/ENERGY/WATER/REPROC/
FUEL/VALVE werten nur MASTER und PROTO_MISMATCH aus; FUEL zusätzlich
RT-Status direkt über den Mithörer und Ventil-Lebenszeichen).

**Stufe 1 (v821) — umgesetzt:** 1088 → 603 Sendungen/min.
- **1a Sollwerte** `master/rt_sync.lua` `setpoint_send_due()`: first /
  changed / rejected (≥ 3 s) / refresh (10 s). HELLO und Wiederverbindung
  nach OFFLINE löschen `last_setpoints_ts` → sofort. Nach einem RT-Neustart
  wartet MASTER wie bisher erst SET_MODE ab (Bestätigung im nächsten
  Status), dann gehen die Sollwerte sofort raus. Die „immer senden"-Tests
  (Aug.-Anpassung an die Dedup-Entfernung vom 25.06.) sind umgeschrieben.
- **1b Logs:** `utils.log` lässt DEBUG nur mit `set xreactor.log_debug true`
  durch (vorher ging **jede** Zeile jeder Stufe per Funk). MASTERs
  Abgleich-Zeilen, RTs angenommene SET_SETPOINTS, FUELs Relais-Empfang →
  DEBUG; „RT plan" nur bei Änderung.
- **1c Relais** alle 10 s ohne Quittung (`payload.no_ack`,
  `comms.command_wants_ack`); alter Empfänger quittiert weiter (harmlos).
- **1d Filter** `comms_service.follower_payload_filter()` für alle Rollen
  außer MASTER.

**Stufe 2 (v822) — umgesetzt: Kanäle aufteilen, selbstumschaltend.**

| Kanal | Inhalt | Wer hört |
|---|---|---|
| 6500 Abwärts | MASTER → alle: Kommandos, MASTER-Heartbeat/Status/Alarm/Hello | alle |
| 6501 Aufwärts | Nodes → MASTER: Heartbeat/Status/Hello/Alarm/Quittungen | MASTER, FUEL, Pocket |
| 6503 Log | Logzeilen | nur Log-Sammler |
| 6505 Log-Antwort | Quittung/Ping des Sammlers | alle |
| 6504 Ventil | FUEL → Ventile (SET_VALVE) | Ventile (+FUEL für alte Ventile) |
| 6506 Ventil-Antwort | Ventile → FUEL (VALVE_ACK, HOP_SCAN, Teach) | nur FUEL |

- **Senden** (`services/comms_service.lua` `_broadcast_channel`): MASTER
  Rundrufe auf 6500, alle anderen auf 6501. Quittungen
  (`core/comms.lua` `send_ack`): Nodes auf 6501, MASTER auf 6500.
- **Uplink schließen** (`listen_uplink = false` in RT, ENERGY, WATER,
  REPROCESSOR, VALVE): erst wenn **Heartbeat oder Status von MASTER auf
  6500** ankommt (`_note_downlink`; Kommandos/Hello zählen NICHT, die
  sendet ein MASTER bis v821 auch dort). 30 s ohne → 6501 wieder offen
  (`_check_uplink`, auch bei Uhr-Rücksprung). Wechsel als INFO
  „Uplink-Kanal 6501 geschlossen / wieder offen". Zustand:
  `comms:get_uplink_state()`.
- **Peers:** dieselben Rollen führen nur MASTER als Peer (`comms.init`
  `track_peer`) — sonst „Peer down" für jede Node, die sie nicht mehr
  hören. Geprüft: alle diese Rollen lesen aus der Peer-Tabelle nur MASTER.
- **Logs** (`core/utils.lua`): jede Zeile trägt `reply_channel = 6505`;
  6505 immer offen, 6503 zu, sobald eine Antwort (Ping oder Quittung, auch
  an eine andere Node) auf 6505 kommt; 60 s Stille auf 6505 → 6503 wieder
  offen. Der Sammler selbst (Rolle LOG/LOG_COLLECTOR) schließt nie.
  **Sammler** (`nodes/log_collector/main.lua` `send_acks`): für Nodes mit
  `reply_channel` EIN LOG_ACK je Schreibvorgang mit `event_ids` (≤ 32) auf
  6505 — bis v821 ging je Logzeile eine Quittung an jeden Rechner; ältere
  Nodes wie bisher einzeln auf 6503. Ping auf 6503 und 6505.
- **Ventile:** SET_VALVE trägt `reply_channel = 6506`; das Ventil
  (`nodes/valve/controller.lua` `reply_channel()`) übernimmt nur 6506 und
  nur von der vertrauten Quelle, quittiert dort und sendet HOP_SCAN/Teach
  dort. FUEL öffnet 6504 und 6506, die drei rohen Hörer nehmen beides.
- **Mischbetrieb** (Auto-Update rollt in beliebiger Reihenfolge): alter
  MASTER → Nodes lassen 6501 offen; alter Sammler → 6503 bleibt offen;
  altes FUEL → Ventile antworten auf 6504; alte Nodes/Ventile → bekommen
  alles wie bisher. Abgesichert in `tests/radio_hygiene_stage2_test.lua`
  (Anlage inkl. alter MASTER, Rückfall nach 30 s) und
  `tests/radio_hygiene_stage2_unit_test.lua` (Randfälle); jede Regel per
  Rückbau gegengeprüft (25 Rückbauten, alle erkannt).
- **Test-Harness:** `cc_node_boot` add_modem merkt offene Kanäle
  (`env:listening_modem`), `node_message_bus` stellt nur bei offenem Kanal
  zu (`net.not_heard`; alt: `ignore_open_channels = true`). Ein Boot
  schließt alle Kanäle. Alle 411 bisherigen Tests liefen damit unverändert.

**Gemessen** (Harness, 3 RT + MASTER + FUEL + REPROC + ENERGY + 4 Ventile +
nachgebildeter Sammler, Empfang je Minute, gleicher Harness für beide
Stände):

| | v821 | v822 |
|---|---|---|
| RT / ENERGY / REPROC / Ventil (je) | ~570 | 92 |
| MASTER | 534 | 482 |
| FUEL | 576 | 518 |
| alle Rechner zusammen | 6236 | 1828 |

**Stufe 3 (v823) — umgesetzt: FUEL fragt die Ventile selbst ab** (Betreiber:
„Ja setze d um", nach dem Vergleich A Kabel / B ohne Ventil-Rechner / C FUEL
zweiteilen / D Software).

Befund: auch nach v822 hörte FUEL den ganzen Uplink — jede Node Heartbeat
alle 2 s + Status alle 5 s (≈ 42/min); in der Anlage des Betreibers (29
Ventile, ~40 Nodes) ≈ 1700/min an FUEL, davon ~70 % die Ventile selbst. Ein
eigener Ventil-Funkkanal hätte FUEL nur ~25 % erspart, den Heartbeat-Takt
darf ich nicht ändern — also hört FUEL die Heartbeats gar nicht mehr.

- **Ping:** FUEL sendet `VALVE_PING` alle 10 s als Rundruf auf 6504
  (`redstone_router.ping_valves`, Dienst `valve_ping` in der schnellen
  Schleife). Ventil ab v823 antwortet `VALVE_PONG` auf 6506
  (`nodes/valve/controller.lua` `_answer_ping`: Name, blocked,
  initialized, error) — nur der vertrauten Quelle (ungepaart: jeder), nur
  auf 6506 oder 6504. Der Ping ändert am Ventil **nichts**: kein Schreiben,
  keine Sicherungsfrist (`last_command_ts`), kein gelernter Kanal.
- **Erreichbarkeit:** `redstone_router.valve_peers()` führt Heartbeat
  (comms) und Ping-Antwort zusammen, das Bessere zählt; Antwort älter als
  20 s → überfällig (kein OPEN), älter als 30 s → weg; Zeitstempel aus der
  Zukunft → überfällig. Ersetzt die rohe Peer-Tabelle an allen fünf
  Router-Stellen; auch die ROUTER-Auswahl (`router_scada.known_valves`).
- **6501 schließen** (`comms_service` `uplink_close_check`, Router
  `uplink_close_check(editing)`): nur wenn MASTER auf 6500 sendet (wie
  Stufe 2), die Ventilketten geladen sind (`routes_loaded` — vorher wäre
  „alle antworten" trivial wahr), kein ROUTER-Editor offen ist und **jedes
  Routen-Ventil** binnen 30 s geantwortet hat. Den Füllstand reicht MASTER
  ohnehin alle 10 s weiter (FUEL_STATUS). Sonst offen; nach dem
  Wiederöffnen frühestens 60 s später wieder zu (`UPLINK_MIN_OPEN_MS`, kein
  Flattern). Solange zu, führt FUEL nur MASTER als Peer; beim Schließen
  vergisst `comms.forget_peers` die übrigen still (kein „Peer down").
- **Mischbetrieb:** Ventil bis v822 antwortet nicht → FUEL lässt 6501 offen
  bzw. öffnet nach 30 s und kennt es über den Heartbeat. FUEL bis v822
  pingt nicht → Ventile ab v823 laufen wie bisher.
- Heartbeat-Takt und -Inhalt aller Nodes unverändert; MASTER hört die
  Ventile weiter direkt.
- Tests: `tests/radio_hygiene_stage3_test.lua` (Anlage mit Ventilkette und
  Lieferung, altes Ventil, Wiederöffnen/Mindest-Offenzeit, Router-,
  Ventil- und comms_service-Randfälle); 20 Rückbauten, alle erkannt; die
  Stufe-2-Rückbauten am neu geschriebenen Uplink-Block erneut geprüft.

**Gemessen** (Harness, 11 Nodes + Sammler, FUEL mit Route über 4 Ventile,
Empfang je Minute, gleicher Harness): FUEL **530 → 128**; Ventile +6
(Pings). Geschätzt für die Anlage des Betreibers: FUEL ≈ 1700 → ≈ 275.

**Noch offen (nur Konzept, siehe Gespräch vom 2026-10-13):** A — Ventile
per eigenem Kabelnetz an FUEL (baut auf Stufe 3 auf; eigenes Netz, nicht
FUELs Peripherie-Kabel, sonst greift die Selbsterkennung der Ventile
fremde Geräte; offene Frage: behalten Kabel-Ventile ihr Ender-Modem für
MASTER?). Nur auf ausdrückliche Freigabe.

## Fehler dieser Sitzung — damit sie sich nicht wiederholen

1. **Der Stab-Dirty-Check** (oben). Das war genau das, was der Betreiber
   beklagt hat: „wir fixen ein sac 3 andere gehn kaput … das mus doch besser
   gehen."
2. **Mein erster `rt2_uneven_control_rods_test.lua` lief auf dem kaputten
   Baum grün** — ich habe `apply_reactor` mit 4 statt 5 Argumenten gerufen
   und damit den Dirty-Check umgangen.
   **Regel: jeder Regressionstest wird gegen den Baum VOR dem Fix gefahren**
   (`git archive HEAD | tar -x -C /tmp/claude-0/preN`) **und muss dort aus dem
   RICHTIGEN Grund scheitern.**
3. **Fassungen v812–v817 gemeldet, die es nicht gibt** — ich hatte Commits
   gezählt statt `release.lua` zu lesen, und die Ausgabe von `manifest_sync`
   mit `>/dev/null` unterdrückt. **Regel: Fassung immer aus `release.lua`
   lesen, nie zählen, Werkzeugausgabe nicht wegwerfen.**
4. **„Die Stabregelung schwingt bei jeder Anlagengröße"** — falsch. Ich hatte
   den Tank auf 200000 mB festgenagelt; bei der realistischen Größe (20000)
   ist die Regelung ruhig.
5. **„MASTER schaltet nur 100 % → 0 %, keine Zwischenstufe"** — falsch. Ich
   hatte je Knoten nur den letzten Sollwert gelesen. Nur die Änderungen
   gedruckt zeigt 2 Knoten auf 80 %, Rest standby/shed: die entworfene
   anteilige Aufteilung.
6. **Lesefehler an den Prüfständen:** `record.to` statt `message.dst` (der
   Bus ist Rundruf — Adressat ist `message.dst`); nur die ersten zwei
   `FUEL_STATUS`-Pakete angesehen (die sind leer, bevor MASTER RT-Daten hat);
   `payload.ok` statt `payload.result.ok`; ein externer
   `peripheral.call`-Zähler, den `Env:activate()` vor jedem Tick still
   ersetzt hat (statt dessen die Stubs instrumentieren).
7. **Baufehler der Harness**, die Zeit gekostet haben: fehlendes `textutils`;
   `dofile` sah das virtuelle Dateisystem nicht; ein kyrillisches `М` in
   `getМethods`; `tick_service` rief `service.tick(ts)` statt
   `service:tick(dt, event)`; `print` von der Erfassung geschluckt;
   `parallel` verworfen, sodass FUELs `after_cycle` nie lief — FUEL sah
   dadurch aus, als hätte es keine Reaktoren.
   **Eine Harness, die falsche Fehler erfindet, ist schlimmer als keine.**
8. **Testerwartungen, die altes Verhalten festschrieben**, wurden mit
   festgehaltener Begründung angepasst, nicht passend gebogen: 15000 → 25000 ms
   in `rt_health_payload_test.lua`, das `getFluidFlowRate`-Rückfallversprechen
   in `turbine_adapter_capability_probe_test.lua`, der `shutdown`-Zustand.
9. **Harness-Fallen der Funk-Hygiene (v822):** `env.logs` bleibt bei
   gebooteten Rollen LEER (sie laden `core.utils` über ihren eigenen
   Modulgraphen) — eine Prüfung „keine Zeile X im Log" darüber ist
   wirkungslos. Gefunkte Logzeilen (LOG_EVENT auf 6503 in
   `env.transmitted`) lesen; aber die Node bündelt nach `os.clock()`, das
   im Harness echte Rechenzeit ist — die jüngsten Zeilen können noch im
   Puffer liegen. Zählen also über Zustandszähler, nicht über Logzeilen.
   MASTER sendet schon beim Boot Status/Heartbeat — wer einen alten
   MASTER nachstellt, muss diese Boot-Meldungen überspringen.

## Arbeitsweise, die gilt

- **Vorsichtig, und lieber neu schreiben als flicken** (Betreibervorgabe
  2026-10-12, gilt immer): siehe oben.
- Lua-Tests: `lua5.2 -e "dofile('tests/cc_env_shim.lua')" tests/<datei>.lua`
- Ablauf: beide Suiten → `python3 scripts/manifest_sync.py --write` → beide
  Suiten erneut → direkt auf `beta` committen und pushen (kein PR, keine
  weiteren Branches).
- `manifest_sync.py --write` hebt die Fassung **bei jedem Lauf** mit
  geänderten Dateien. Ändert man danach noch etwas, vor dem zweiten Lauf
  `manifest_version`/`manifest_id` (und `release_id`) in `manifest.lua`
  und `release.lua` auf den alten Stand zurücksetzen — sonst springt die
  Fassung um zwei.
- **Konfig-Falle:** `core/utils.migrate_config()` ergänzt Vorgaben **und
  schreibt sie fest**. Jede Änderung einer Vorgabe braucht eine
  Schema-Migration (RT steht auf v9).
- **Heißer Pfad bleibt namensbasiert** (`peripheral.call` /
  `utils.safe_peripheral_call`). Genau das lässt den Regler Chunk-Nachladen
  überleben; langlebige `peripheral.wrap`-Handles sind das zerbrechliche
  Muster.
- Reiner Entscheidungskern: alle `rt2_*` sind rein, unrein sind nur
  `rt2_adapter.lua` (Peripherie) und `rt2_engine.lua` (Persistenz/Fassade).
  Zustand je Turbine liegt in `rt2_orchestrator.lua`.
- Echte Regelperiode: **100 ms** (`RECEIVE_TIMEOUT = 0.1` in
  `nodes/rt/main.lua`).

## Nächste Schritte

1. **Im Betrieb beobachten** (sobald der Betreiber wieder im Spiel ist):
   - MASTER, Seite **Updates**: alle Knoten auf v823? Spalte **DATEIEN**
     nach dem ersten Update-Check „OK" (vorher „?").
   - Startzeile jedes Knotens: `beta-v823 (Pruefsumme 8f7c66a7)`.
   - **Nach v823 (Stufe 3):** FUEL loggt „Uplink-Kanal 6501 geschlossen:
     alle Ventile antworten auf VALVE_PING …". Steht dort stattdessen
     „… Ventil X antwortet nicht auf VALVE_PING", ist X noch nicht auf
     v823 oder nicht erreichbar (Seite VENTILE). Seite VENTILE: alle
     Ventile online, „FUEL-LAST" bei 0?
   - **Nach v822 (Funk-Hygiene Stufe 2):** RT/ENERGY/WATER/REPROC/VALVE
     loggen einmal „Uplink-Kanal 6501 geschlossen: MASTER sendet auf dem
     Downlink 6500 …", jede Node „Log-Kanal 6503 geschlossen: der
     LOG_COLLECTOR antwortet auf 6505", jedes Ventil nach der ersten
     Schaltung „Antwortkanal zu FUEL: 6506". Taucht „Uplink-Kanal 6501
     wieder offen" öfter auf, war MASTER ≥ 30 s still (Neustart,
     Chunk) — das ist harmlos, sollte aber selten sein. Seite VENTILE:
     werden jetzt alle Ventile gehört, steht „FUEL-LAST" bei 0?
   - **FUEL nach dem Start (v818):** wenige Sekunden „Ventile melden sich
     noch", dann entweder bereit — oder „Ventil-Kennung unbekannt" mit den
     IDs, die nicht passen: dann ROUTER > Ventilkette neu einlernen (siehe J).
     „Ventil-Verbindung nicht bereit" heißt nur noch: Ventil war da und ist
     weg.
   - **FUEL-Seite VENTILE (v819, Seite 4/5):** welche IDs stehen auf
     UNBEKANNT / OFFLINE, seit wann (ZULETZT), in welcher Kette
     (REAKTOREN)? Mit den VALVE-Schirmen (zeigen ihre eigene ID) abgleichen.
     Steht „WARTET" länger als eine Minute, startet FUEL neu — dann
     FUEL-Log ansehen (siehe K).
   - **Nach v820:** Seite VENTILE, Zeile 5 „FUEL-LAST: Timer verloren …".
     Bleibt sie bei 0 und werden alle Ventile gehört, ist die Überlast weg.
     Steigt die Zahl weiter, reicht die Entlastung von FUEL allein nicht —
     dann VALVE-Nodes ebenfalls entlasten (siehe L, nächster Schritt).
   - FUEL-Log nach dem Start: „FUEL-Route '…': Reaktor-Kennung … -> …
     (global, gespeichert)" für alte Routen; Meldungen „… im ROUTER neu
     einlernen" für Routen, die sich nicht zuordnen lassen — die dann im
     Router neu einlernen und die alte löschen.
   - RT-Diagnoseseite nach dem nächsten Chunk-Laden: „TIMER LOST / LATE";
     MASTERs Terminal: „[MASTER] Takt-Timer ausgeblieben …".
   - RT-Schirm, Seite Turbinen: zeigt eine Turbine „-", kann auch der
     Regler sie nicht lesen (seit v815 derselbe Leseweg).
   - ENERGY kurz nach dem Start: eine Matrix ohne Kapazität steht auf
     „n/a", nicht auf 100 %; kein `MATRIX_NEAR_FULL` beim Hochfahren.
   - Auto-Updater-Statusdatei `/xreactor_config/auto_update_status.txt`:
     „Dateipruefung ok: N Dateien passen zu manifest-v823 / Pruefsumme …".
   - Log nach einem Geräteausfall: dieselbe Warnung („Turbine call failed …")
     kommt nach einer Erholung beim NÄCHSTEN Ausfall wieder (seit v817),
     höchstens einmal je Minute.
2. Selbstheilung Ebene 2 → 3 (Ebene 1 erledigt, siehe I), Ebene 3 nur auf
   ausdrückliche Ansage. Sinnvoll erst, wenn sich im Betrieb zeigt, dass
   Knoten nach dem Chunk-Laden trotz v812–v817 noch hängen.
3. `beta` → `main`, sobald alles läuft (Betreiber).

Gestrichen am 2026-10-12 (Betreiber): das am 2026-10-04 angekündigte
„weitere Thema, indirekt damit zusammenhängend" (er wusste es nicht mehr),
die MASTER-Ausfall-Befunde A und B und die P2-Liste des Audits zu
beta-v799 (Inhalt beider nicht im Repo; das Verhalten bei MASTER-Ausfall
ist durch `plant_scenarios_test.lua` abgesichert).

---

# Aelterer Bestand (Stand 2026-09-25, weiterhin gueltig)

## Rollback-Marken

Die Marken-Branches (`stable-beta-*`) wurden am 2026-10-04 geloescht -- auf
GitHub gibt es nur noch `beta` und `main`. Die Staende liegen weiter in der
Historie von `beta` und lassen sich ueber die **volle Commit-ID**
installieren: der Installer nimmt statt `beta` jede Ref aus
`__xreactor_forced_ref` (`installer:109-114`). Tags sind keine Alternative,
Tag-Pushes scheitern in dieser Umgebung reproduzierbar
(`send-pack: unexpected disconnect`).

| Stand | Commit | |
|---|---|---|
| v770 | `b09c11231b9b7c8f305d9274886a36a99f76b15a` | **juengster vom Betreiber bestaetigter Stand** (2026-09-28: vereinfachter Regler, Doppelsetup -- siehe RT_ENGINE_V2.md) |
| v768 | `98e1eebc5f7f01676d0648ea383998011407b590` | stornierter Update-Quiesce laesst die Node nicht mehr stehen |
| v761 | `f348d4ba72d7d5bc3aee006970dae6c5cb3569ff` | RT-Regler im Betrieb bestaetigt, FUEL liefert, Dampftank-Sollwert 70 % |
| v742 | `ac122a05f5ece1ff7587aaf15669331bde6cacea` | RT bestaetigt mit 1 Reaktor / 25 Turbinen, FUEL noch defekt |

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
  seit dem Umstieg auf v2 unerreichbar. Der Sollwert des Dampftanks steht
  in `rt2_reactor.DEFAULT_TARGET_FILL` (0.7). **Offen:** er ist damit nur
  im Code aenderbar, nicht mehr per Kommando oder Config —
  `rt2_orchestrator` reicht `target_fill` nicht aus der Konfiguration
  durch. Das war schon vorher so, faellt jetzt aber staerker auf.

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
