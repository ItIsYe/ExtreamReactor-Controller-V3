# Session Handoff — XReactor Controller V3

**Stand: 2026-10-04 | beta | manifest-v812 | HEAD `72a7b285`**

---

# Übergabe Sitzung 2026-10-04 — RT-Durchgang, Anlagentest, Selbstheilung

**Startinfo für eine neue Sitzung.** Alles darunter ist älterer Bestand und
weiterhin gültig, aber nicht Gegenstand dieser Sitzung.

## Stand bei Übergabe

| | |
|---|---|
| Branches | auf GitHub nur noch `beta` (Arbeitsstand) und `main` (wenn alles läuft); alle anderen am 2026-10-04 gelöscht |
| HEAD | `72a7b285` |
| Fassung | `manifest-v812` / `beta-v812` (aus `xreactor/release.lua`, nicht gezählt) |
| Tests | 392 Lua + 44 Python, grün |
| Arbeitsbaum | sauber, nichts Unverbuchtes |
| Sprache | Oberfläche, Kommentare und Commit-Texte **deutsch** |
| Ablauf | direkt auf `beta` committen und pushen, **kein PR** (Betreiberentscheidung 2026-10-04) |

### ⚠️ Stehende Vorgabe des Betreibers, am Sitzungsende noch in Kraft

> „achtung nichts umsetzen nur prüfen und iden konzept geben"

Seither wird nur umgesetzt, was der Betreiber **einzeln freigibt**.
Freigegeben und umgesetzt (Folgesitzung 2026-10-04): der Chunk-Test, der
Schleifen-Fix (v812) und die CI-Remote-Prüfung. Alles andere braucht weiter
eine ausdrückliche Freigabe, bevor Code angefasst wird. Der Betreiber kann derzeit **nicht im Spiel testen**
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

**Behoben in v812** (`wait_cycle`): weiter, wenn der eigene Timer kommt ODER
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

**Dasselbe Muster, noch nicht behoben:** `master/loop.lua:75`,
`nodes/energy/matrix.lua:26`, `installer/auto_update.lua:459`,
`nodes/log_collector/main.lua:1329` und `:1365`; dazu `run_event_loop` in
`runtime.lua`, das niemand mehr aufruft.

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
Update. **B1/B2 allein reicht dafür nicht** — auch das wrap-Handle in
`ctx.peripherals.turbines` (`discovery_runtime.lua:54-55`) ist veraltet;
besser den Quiesce namensbasiert über `adapters/turbine.lua` führen.

**B3** (Monitor-Handle, ungeprüft): RT wickelt `devices.monitor` nur einmal
in `init()` (~`:745`) und nutzt es in jedem UI-Tick (~`:483`); `discover()`
löst es nie neu auf (`monitor_name = nil`, ~`:305`) — anders als
FUEL/WATER/REPROCESSOR.

### B) Selbstheilung — Konzept in drei Ebenen (letzte Antwort der Sitzung)

1. **Abgeleiteter Zustand darf nie dauerhaft sein.** Negative Ergebnisse
   verfallen mit Zeitstempel, positive bleiben. Beweisgetriebene Verwerfung:
   gelingt ein Aufruf, den der Cache für unmöglich hält, fliegt der Eintrag.
   `getMethods`-Fehlschlag von „keine Methoden" trennen.
   `warn_once`/`shouted` zurücksetzbar machen, sonst ist die *nächste*
   Störung stumm. Vorbild: `adapters/turbine.lua:176-195`. Risiko niedrig.
   **Diese Ebene behebt den Update-Quiesce, nicht das Feldbild** (siehe A).
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
belegt, die Wirkung fehlt. Ebenfalls auffällig:
`service_manager.lua:65` `schedule_retry` wiederholt mit Backoff, verwirft
dabei aber **nie** das Handle oder den abgeleiteten Zustand, an dem es
scheitert.

**Reihenfolge: Betrieb beobachten (TIMER LOST, siehe A) → Ebene 1 →
Ebene 2 → Ebene 3.** Das Chunk-Modell steht
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
(`node_id:local_id`).

### E) Versionierung

`scripts/manifest_sync.py --write` hebt `manifest_version`/`manifest_id`
**nur**, wenn manifest-geführte Dateien sich ändern; `release.lua` ist als
selbstbezüglich ausgenommen. **Tests und Dokumentation stehen nicht im
Manifest** — Commits, die nur daran rühren, heben die Fassung nicht.
`installer/auto_update.lua:374` aktualisiert bei
`remote_version > local_version`. `commit_sha = "beta"` ist ein gewollter
Platzhalter, `scripts/package_release.py:48` setzt für feste Releases eine
echte SHA. Offenes Konzept: **Payload-Digest statt reinem Zähler**,
Entscheidung steht aus.

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

## Arbeitsweise, die gilt

- Lua-Tests: `lua5.2 -e "dofile('tests/cc_env_shim.lua')" tests/<datei>.lua`
- Ablauf: beide Suiten → `python3 scripts/manifest_sync.py --write` → beide
  Suiten erneut → committen und pushen (`origin/beta` **und** Branch).
- **Konfig-Falle:** `core/utils.migrate_config()` ergänzt Vorgaben **und
  schreibt sie fest**. Jede Änderung einer Vorgabe braucht eine
  Schema-Migration (RT steht auf v8).
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

1. **Im Betrieb beobachten:** nach dem nächsten Chunk-Laden die
   RT-Diagnoseseite, Zeile „TIMER LOST / LATE" (siehe A). LOST über 0
   belegt die Ursache. Hängt die Node trotzdem bei LOST 0: Fehlerbild
   sammeln (Schirm, Modus, welcher Chunk).
2. **Derselbe Fix für die übrigen Schleifen** (MASTER, ENERGY-Matrix,
   Auto-Updater, Log-Collector) und der Update-Quiesce (B1/B2 plus
   wrap-Handle) — jeweils Freigabe nötig.
3. Selbstheilung Ebene 1 → 2 → 3, Ebene 3 nur auf ausdrückliche Ansage.
4. Versionierung: Entscheidung zum Payload-Digest.
5. Älter und noch offen: MASTER-Ausfall-Befunde A und B;
   `matrix_snapshot_runtime.lua` Kapazitäts-Rückfall; die P2-Liste des
   Audits.
6. **Turbinenzahl je RT-Knoten ist unbekannt** — der Anlagentest nimmt 3 an
   (Flotte 547 200 RF/t). Nachfragen und anpassen.
7. **Der Betreiber hatte „noch ein weiteres Thema, aber indirekt damit
   zusammenhängend" angekündigt und nie genannt. Danach fragen.**

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
