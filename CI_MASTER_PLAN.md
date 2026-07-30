# CI Master Plan: sichere, game-nahe Validierung

> **Status:** verbindliches Zielbild und Implementierungsgrundlage, noch nicht vollständig umgesetzt  
> **Stand:** 2026-07-30  
> **Basis:** Branch `beta`, Release/Manifest v476  
> **Adressaten:** Maintainer, Coding-Agenten und Reviewer

Dieses Dokument ist die kanonische technische Vorgabe für den Umbau der CI. Es ersetzt keine bestehenden Funktions- oder Architekturunterlagen, sondern führt die Anforderungen aus `TESTPLAN.md`, dem aktuellen CI-Audit und den realen CC:Tweaked-/Minecraft-Randbedingungen in einem umsetzbaren Zielbild zusammen.

Die zugehörige, schrittweise Aufgabenliste steht in [CI_IMPLEMENTATION_BACKLOG.md](CI_IMPLEMENTATION_BACKLOG.md).

---

## 1. Ziel

Die CI muss gleichzeitig vier Eigenschaften erfüllen:

1. **Schnell:** offensichtliche Fehler wie Syntax-, Struktur-, Manifest- und Releasefehler werden früh erkannt.
2. **Streng:** ein grüner Lauf darf keine bekannten kritischen Fehler durch Skip-Listen oder unvollständige Guards verdecken.
3. **Game-nah:** derselbe Produktivcode läuft in einer deterministischen Simulation der relevanten CC:Tweaked- und Anlagenumgebung.
4. **Release-sicher:** kein Commit wird automatisch an Nodes verteilt, bevor alle verpflichtenden Gates erfolgreich waren.

Eine perfekte Erkennung aller möglichen Fehler ist nicht realistisch. Das Ziel ist stattdessen **Defense in Depth**: mehrere unabhängige Prüfschichten, die unterschiedliche Fehlerklassen erkennen und sich gegenseitig absichern.

---

## 2. Nicht verhandelbare Grundsätze

### 2.1 Produktivcode statt Testkopie

Die Simulation darf keine vereinfachte Kopie der Steuerungslogik enthalten. Sie stellt nur Umgebung und Hardware bereit. Gestartet werden dieselben Entry-Points wie im Spiel:

- `xreactor/master/main.lua`
- `xreactor/nodes/rt/main.lua`
- `xreactor/nodes/energy/main.lua`
- `xreactor/nodes/water/main.lua`
- `xreactor/nodes/fuel/main.lua`
- `xreactor/nodes/reprocessor/main.lua`
- `xreactor/nodes/log_collector/main.lua`

### 2.2 Kein falsches Grün

Ein Workflow ist nicht erfolgreich, wenn:

- ein kritischer Test übersprungen wurde,
- ein Testprozess nicht gestartet werden konnte,
- keine Tests gefunden wurden,
- eine Ausschlussliste unerwartet wächst,
- ein Test nur wegen fehlender Abhängigkeiten nicht ausgeführt wurde,
- Manifest, Release und veröffentlichte Dateien nicht denselben Stand abbilden.

### 2.3 Determinismus

Jeder Simulationstest besitzt:

- eine virtuelle Uhr,
- einen festen Zufalls-Seed,
- eine reproduzierbare Eventreihenfolge,
- begrenzte Simulationsdauer,
- vollständige Diagnoseartefakte bei Fehlern.

Ein gefundener Fehler muss lokal mit demselben Seed und Szenario reproduzierbar sein.

### 2.4 Sicherheitslogik hat Vorrang

Für folgende Bereiche sind im Release-Gate keine Skips erlaubt:

- SAFE/SCRAM
- Coolant- und Temperatur-Safety
- Reactor-Rod-Regelung
- Turbinen-Overspeed und Flow-Bremse
- Shutdown- und ACK-Semantik
- RT-Synchronisation und globaler Hold
- Update-/Installer-Atomizität

### 2.5 CI und Deployment sind getrennt

Der Entwicklungsbranch darf nicht gleichzeitig die automatisch konsumierte Distributionsquelle sein. Ein getesteter Commit wird bewusst auf einen Deployment-Ref oder unveränderlichen Release-Ref promoviert.

---

## 3. Audit-Baseline vom 2026-07-30

### 3.1 Aktueller Workflow

Die vorhandene `.github/workflows/ci.yml` führt in einem Job aus:

1. Repository-Checkout
2. Installation von Lua 5.2
3. `lua tools/offline_validate.lua`
4. `bash tools/run_lua_tests.sh`
5. `bash tools/run_python_tests.sh`

Das ist als Basis wertvoll, deckt aber noch keine realistische CC:Tweaked-Laufzeit oder Anlagenphysik ab.

### 3.2 Bestehende Stärken

- Parse-Prüfung aller Lua-Dateien unter `xreactor/`
- Manifest-Dateipfade werden gegen das Repository geprüft
- vollständige Größen- und CRC-Prüfung über `scripts/manifest_sync.py`
- transitive `require()`-/`dofile()`-Abdeckung für Rollen-Entrypoints
- isolierte Prozesse pro Lua-Test
- ein minimaler CC:Tweaked-Shim für Host-Lua
- vorhandene Regressionstests für viele reale historische Fehler

Relevante Dateien:

- `.github/workflows/ci.yml`
- `tools/offline_validate.lua`
- `tools/run_lua_tests.sh`
- `tools/run_python_tests.sh`
- `tests/cc_env_shim.lua`
- `scripts/manifest_sync.py`
- `tests/manifest_hash_size_guard_test.py`
- `tests/manifest_entrypoint_require_coverage_test.py`

### 3.3 Kritische Lücken

Zum Auditzeitpunkt werden über die Ausschlusslisten **63 Lua-Tests und 6 Python-Tests** nicht ausgeführt. Dazu gehören Safety-, Control-, RT-Sync-, Shutdown-, Energy- und Releaseprüfungen.

Relevante Dateien:

- `tests/known_failing_lua_tests.txt`
- `tests/known_failing_python_tests.txt`

Mehrere im `TESTPLAN.md` als verpflichtend beschriebene Tests stehen gleichzeitig in den Ausschlusslisten. Damit ist ein grüner Lauf aktuell kein belastbarer Release-Nachweis.

Weitere Lücken:

- `manifest_changed_files_guard_test.py` verwendet `git status --porcelain` und erkennt in einem sauberen Actions-Checkout nicht zuverlässig die Änderungen gegenüber dem Basisbranch.
- `release_metadata_consistency_test.lua` ist ausgeschlossen und erwartet Metadaten, die der aktuelle Release-Stand nicht vollständig bereitstellt.
- die Remote-Prüfung aus `scripts/verify_remote_manifest.py` läuft nicht als verpflichtender Post-Deployment-Check.
- `beta` ist Entwicklungs- und Auto-Update-Quelle zugleich.
- es gibt keine vollständige Simulation von Eventqueue, Timer, Parallelität, Modems, Peripherien oder Maschinenzuständen.

---

## 4. Zielpipeline

```text
Pull Request
    |
    +-- 01 repository-integrity
    +-- 02 syntax-and-static-analysis
    +-- 03 manifest-and-release-integrity
    +-- 04 unit-and-regression
    +-- 05 deterministic-cc-simulation
    +-- 06 critical-plant-scenarios
    |
Merge nach main
    |
    +-- 07 full-scenario-matrix
    +-- 08 trace-replay
    +-- 09 property-and-chaos-tests
    |
Release-Kandidat
    |
    +-- 10 real-game-smoke / GameTest-Server
    +-- 11 immutable-package
    +-- 12 promotion auf deploy/beta
    +-- 13 remote-manifest-verification
```

Alle Stufen ergänzen einander. Syntax-, Manifest- und Releaseprüfungen bleiben vollständig erhalten und werden verschärft. Die Simulation ist eine zusätzliche Schicht.

---

## 5. Prüfschicht 1: Repository-Integrität

Diese Stufe muss sehr schnell laufen und bei strukturellen Fehlern sofort abbrechen.

### Pflichtprüfungen

- keine Merge-Konfliktmarker
- keine verbotenen Altpfade
- keine fehlenden Pflichtdateien
- keine unerwarteten Binärdateien
- keine doppelten Modulpfade
- keine manifestierten Dateien außerhalb des erlaubten Baums
- alle Shell-Skripte mit `bash -n`
- alle Python-Dateien mit `python -m compileall`
- Workflow-YAML syntaktisch validieren
- Test-Discovery muss mindestens die erwartete Mindestanzahl finden
- Skip-Listen müssen parsebar sein

### Akzeptanzkriterien

- kein Fehler wird als Warnung herabgestuft
- „0 Tests gefunden“ ist ein harter Fehler
- der Job hat ein festes Timeout
- Diagnose nennt Datei, Regel und erwartete Korrektur

---

## 6. Prüfschicht 2: Lua-Syntax und CC:Tweaked-Kompatibilität

Host-Lua 5.2 bleibt als schnelle Parse-Stufe erhalten. Es ist aber nicht identisch mit der CC:Tweaked-Cobalt-Laufzeit und darf nicht der einzige Runtime-Nachweis sein.

### Pflichtprüfungen

- `loadfile()` über alle ausgelieferten Lua-Dateien
- Parse des Root-Installers
- Parse der Rollen-Entrypoints
- Register-/Local-Limits für große Dateien, insbesondere RT
- Prüfung verbotener APIs, die in CraftOS nicht existieren
- Prüfung bekannter Parallelitätsfallen
- mindestens eine Cobalt-/CC:Tweaked-nahe Ausführungsschicht

### Zu prüfende Kompatibilitätsrisiken

- Lua-5.2-Features, die Cobalt anders oder nicht unterstützt
- `os.execute`/`os.exit` fehlen in CC:Tweaked
- Verhalten von `_ENV`, `loadfile`, `package` und Coroutinen
- `parallel` verteilt Events anders als ein einfacher Host-Lua-Scheduler
- Timer werden auf Minecraft-Ticks von 0,05 Sekunden aufgerundet

---

## 7. Prüfschicht 3: Manifest- und Releaseintegrität

Diese Schicht ist ein hartes Release-Gate.

### 7.1 Manifestregeln

Die CI muss beweisen:

- jede Manifestdatei existiert
- jede zu veröffentlichende Datei ist im Manifest
- kein Pfad kommt doppelt vor
- `size_bytes` stimmt bytegenau
- `hash` stimmt
- `hash_algo` ist bekannt und konsistent
- jede Rolle erhält alle transitiv benötigten Module
- rollenspezifische Dateien werden nicht unnötig global ausgeliefert
- Pflichtdateien wie Entry-Points sind enthalten
- `manifest_file_count` entspricht der tatsächlichen Anzahl
- entfernte Dateien bleiben nicht als tote Einträge zurück

### 7.2 Release-Regeln

Zwischen `xreactor/release.lua` und `xreactor/manifest.lua` müssen mindestens übereinstimmen:

- `manifest_version`
- `manifest_id`
- `source_ref`
- `hash_algo`
- tatsächliche Dateianzahl

Zusätzlich:

- Release- und Manifestversion dürfen nicht sinken
- Release-ID muss zur Version passen
- Änderungen an ausgeliefertem Verhalten benötigen einen Bump
- Manifest und Release müssen im selben Release-Änderungssatz aktualisiert werden
- der Release-Kandidat muss einen unveränderlichen Commit identifizieren
- Installer-Metadaten müssen zum ausgelieferten Installer passen

### 7.3 Changed-Files-Guard

`tests/manifest_changed_files_guard_test.py` muss auf einen echten Vergleich umgestellt werden:

- Pull Request: Merge-Base gegen PR-Head
- Push: vorheriger Commit gegen aktuellen Commit
- Checkout mit ausreichender Historie (`fetch-depth: 0` oder gezieltes Fetch)

`git status --porcelain` ist hierfür nicht ausreichend.

### 7.4 Remote-Verifikation

Nach der Promotion muss verpflichtend ausgeführt werden:

```bash
python3 scripts/verify_remote_manifest.py \
  --base-url <published-xreactor-url> \
  --check-local \
  --expected-manifest xreactor/manifest.lua \
  --require-path shared/build_info.lua
```

Die Prüfung muss die Remote-Dateien selbst laden und gegen das erwartete lokale Manifest vergleichen.

---

## 8. Prüfschicht 4: Unit- und Regressionstests

Die heutigen Tests bleiben erhalten. Sie werden nach Fachbereich aufgeteilt, damit Fehler parallel sichtbar werden.

Empfohlene Jobs:

- `unit-core`
- `unit-installer`
- `unit-master`
- `unit-rt`
- `unit-energy`
- `unit-support-nodes`
- `protocol-and-comms`
- `ui-models`

### Skip-Governance

Jeder Skip benötigt maschinenlesbare Metadaten:

```text
path | category | issue | owner | added | expires | release_blocking
```

Regeln:

- neue Skips dürfen ohne explizite Freigabe nicht hinzukommen
- Gesamtzahl darf in normalen PRs nicht steigen
- abgelaufene Skips machen die CI rot
- unbekannte Kategorien machen die CI rot
- kritische Bereiche dürfen im Release-Gate nicht geskippt werden
- `CONTENT_DRIFT` ist kein Dauerzustand, sondern ein Untersuchungsauftrag

Zulässige Kategorien während der Migration:

- `STALE_API`
- `STALE_STRUCTURE`
- `NEEDS_SIMULATOR`
- `NEEDS_REAL_GAME`
- `KNOWN_BUG`

`CONTENT_DRIFT` soll durch `KNOWN_BUG` oder eine konkret begründete Testkorrektur ersetzt werden.

---

## 9. Prüfschicht 5: deterministische CC:Tweaked-Simulation

### 9.1 Ziel

Der Simulator bildet die für XReactor relevanten Eigenschaften von CraftOS/CC:Tweaked nach, ohne die Produktivlogik nachzubauen.

Empfohlene Struktur:

```text
tests/sim/
  cc/
    kernel.lua
    scheduler.lua
    event_queue.lua
    timers.lua
    parallel.lua
    filesystem.lua
    settings.lua
    http.lua
    peripherals.lua
    modem_bus.lua
    terminal.lua
    monitor.lua
  peripherals/
    reactor.lua
    turbine.lua
    energy_matrix.lua
    inventory.lua
    fluid_storage.lua
    valve.lua
  plant/
    reactor_turbine_system.lua
    energy_system.lua
    resource_system.lua
  scenarios/
  invariants/
  fixtures/
  runner.lua
```

### 9.2 Virtueller Kernel

Mindestens zu implementieren:

- `os.pullEvent()`
- `os.pullEventRaw()`
- Eventfilter
- `terminate`
- `os.queueEvent()`
- `os.startTimer()`
- `os.cancelTimer()`
- 50-ms-Tickrundung
- `sleep()`
- `parallel.waitForAny()`
- `parallel.waitForAll()`
- separate Eventkopie pro paralleler Funktion
- Computer-ID und Label
- Reboot und Shutdown
- virtuelles Dateisystem mit Kapazitätsgrenze
- `settings` inklusive `setting_changed`
- asynchrone HTTP-Ergebnisse
- Monitor- und Terminalgrößenänderungen
- Peripheral-Attach und `peripheral_detach`

### 9.3 Modembus

Die Simulation muss das reale `modem_message`-Schema liefern:

1. Eventname
2. Modemseite
3. Kanal
4. Reply-Kanal
5. Nachricht
6. Distanz oder `nil`

Nur offene Kanäle empfangen. Unterstützte Fehlerprofile:

- Verlust
- Duplikat
- Verzögerung
- Umordnung
- veraltetes ACK
- ACK nach Retry
- Partition
- Reconnect
- doppelte Node-ID
- beschädigte Payload
- alte Protokollversion

### 9.4 Dateisystem und HTTP

Der Updatepfad muss unter anderem testen:

- HTTP 404/500/Timeout
- HTML statt Lua
- Teilantwort
- beschädigte Datei
- Manifest und Datei aus unterschiedlichen Ständen
- Festplatte voll
- Reboot mitten im Update
- Wiederanlauf nach abgebrochenem Install
- Erhalt der Rollen- und Node-Konfiguration

---

## 10. Prüfschicht 6: dynamische Anlagenmodelle

Statische Rückgabemocks sind nicht ausreichend. Setter müssen den Anlagenzustand über Zeit beeinflussen, und Readback darf verzögert sein.

### 10.1 Reactor-Modell

Mindestens:

- aktiv/inaktiv
- Rod-Insertion 0–100
- Temperatur
- Brennstoff und Waste
- Coolant-Menge und Kapazität
- Steam-Menge und Kapazität
- Produktion
- thermische Trägheit
- verzögerte Rod-Wirkung
- verzögertes Readback
- temporäre Sensorfehler
- unterschiedliche API-Varianten

Der Simulator muss die vom Adapter unterstützten Varianten abdecken, unter anderem:

- `getFuelTemperature` / `getTemperature` / `getCasingTemperature`
- `getEnergyStats` und Einzelmethoden
- `getFuelStats` und Einzelmethoden
- mehrere Rod-Lese- und Schreibpfade
- Hot-Fluid-/Steam-Varianten
- Coolant-Amount-/Percentage-Varianten

Relevanter Produktivcode: `xreactor/adapters/reactor.lua`.

### 10.2 Turbinenmodell

Mindestens:

- RPM
- Massenträgheit
- Steam-Flow
- Flow-Limit
- Coil-Zustand
- Generatorlast
- Energieproduktion
- Overspeed
- verzögerte Setterwirkung
- blockierte oder fehlschlagende Setter

Relevanter Produktivcode: `xreactor/adapters/turbine.lua`.

### 10.3 Energy-Modell

Mindestens:

- gespeicherte Energie
- Kapazität
- Input/Output
- mehrere Ports derselben Matrix
- mehrere Matrizen
- stabile und instabile Identität
- temporär nicht verfügbare Daten
- langsame API-Aufrufe
- wechselnde Topologie
- Lastspitzen
- Last-good-Snapshot

---

## 11. Szenariotests

Ein Szenario beschreibt Topologie, Zeitlinie, Fehler und Invarianten. Beispiel:

```lua
return {
  name = "master loss during turbine overspeed",
  seed = 18421,

  topology = {
    master = 1,
    rt_nodes = 2,
    reactors_per_rt = 1,
    turbines_per_rt = 4,
  },

  timeline = {
    { at = 0.0, action = "boot_all" },
    { at = 20.0, action = "set_power", value = 80 },
    { at = 35.0, action = "force_turbine_rpm", node = "RT-1", turbine = 2, value = 1050 },
    { at = 36.0, action = "disconnect_master" },
    { at = 55.0, action = "reconnect_master" },
  },

  invariants = {
    "no_uncaught_error",
    "overspeed_forces_flow_zero",
    "control_loop_keeps_running",
    "safe_recovery_order",
  },
}
```

### Pflichtszenarien

#### Boot und Discovery

- alle Rollen normal
- MASTER startet vor Nodes
- Nodes starten vor MASTER
- LOG fehlt
- Peripheral erscheint nach Boot
- Peripheral verschwindet während des Betriebs
- zwei gleichnamige Geräte

#### Reactor/Safety

- Coolant kurzzeitig niedrig
- Coolant länger als Pending-Zeit niedrig
- Coolant erholt sich während Pending
- Übertemperatur
- SAFE übersteuert normale Rod-Clamps
- Steam-Tank voll/leer
- mehrere Reaktoren mit unterschiedlichen Zuständen

#### Turbinen

- normaler Ramp-up
- Readback-Lag
- Overspeed
- Overspeed mit verzögertem Flow-0-Readback
- Coil-Setter schlägt fehl
- Turbine detach/attach
- 25+ Turbinen

#### Kommunikation

- Nachrichtenverlust
- Duplikate
- Reihenfolgefehler
- Partition
- veraltete Statuspakete
- falsche Node-ID
- Retry und verspätetes ACK
- MASTER-Neustart

#### ENERGY

- einzelne Matrix
- mehrere Matrizen
- mehrere Ports derselben Matrix
- instabile API-Identität
- langsame Calls
- Sampling-Backlog
- Heartbeat unter Last
- Topologieänderung

#### Installer/Update

- Fresh Install
- Reinstall
- Auto-Update
- beschädigtes Manifest
- inkonsistente Remote-Dateien
- Festplatte voll
- Abbruch und Neustart
- Konfigurationserhalt

---

## 12. Sicherheitsinvarianten

Invarianten werden in jedem relevanten Simulations-Tick geprüft, nicht nur am Ende.

Pflichtinvarianten:

- `0 <= rod_level <= 100`
- `0 <= turbine_flow <= configured_max`
- Overspeed erzwingt Flow-Soll `0`
- SAFE/SCRAM darf nicht durch normale Config-Clamps blockiert werden
- bestätigter Coolant-Mangel verhindert weitere Leistungserhöhung
- ein veraltetes ACK bestätigt keinen neueren Befehl
- Duplikate führen nicht zu doppelter Wirkung
- UI- und Monitorfehler stoppen keinen Control-Loop
- Heartbeats bleiben unter Discovery-/UI-/Sampling-Last innerhalb des Budgets
- ein Sensorfehler führt nicht sofort zu unkontrollierter Oszillation
- ein Update hinterlässt keinen gemischten Dateistand
- ein Node startet niemals mit einer halb geschriebenen Rolle
- keine ungefangene Exception bleibt ohne reproduzierbares Artefakt

---

## 13. Trace Recorder und Replay

Um die Simulation an das reale Spiel anzunähern, wird ein Ingame-Recorder benötigt.

Er zeichnet auf:

- Computer-ID und Rolle
- Zeit/Tick
- Eventname und Parameter
- Peripheral-Name und Typ
- Methodenaufruf und Argumente
- Rückgabe oder Fehler
- Modemnachrichten
- Setter und späteren Readback
- relevante Statusübergänge

Anforderungen:

- sensible Tokens oder private Daten werden vor Speicherung entfernt
- Format ist versioniert
- Traces sind als Fixtures reproduzierbar
- Replay startet den echten Produktivcode
- Abweichungen werden als strukturierter Diff ausgegeben

Trace-Replay ist ein Merge-Gate für bekannte reale Fehler und ein Nightly-Gate für die vollständige Fixture-Sammlung.

---

## 14. Property-, Chaos- und Mutationstests

### Property-/Fuzztests

Generierte Dimensionen:

- 1–8 RT-Nodes
- 1–4 Reactoren pro RT
- 0–32 Turbinen
- zufällige Bootreihenfolge
- zufällige Verzögerungen
- zufällige Sensorabweichungen
- zufällige Reboots
- zufällige Attach/Detach-Events
- zufällige Netzwerkfehler

Bei Fehler werden gespeichert:

- Seed
- minimiertes Szenario
- Eventtrace
- Nachrichten
- Peripheral-Aufrufe
- Anlagenzustände
- Logs
- Dateisystem-Diff

### Mutationstests

Mindestens kritische Mutationen:

- Vergleichsoperator umdrehen
- Coolant-Pending entfernen
- Overspeed-Flow-0 entfernen
- ACK-Deduplizierung deaktivieren
- Rod-Clamp umgehen
- Safety-Priorität absenken
- Heartbeat-Pump überspringen
- Manifest-Hashprüfung deaktivieren

Eine überlebende kritische Mutation bedeutet, dass ein Test fehlt oder unwirksam ist.

---

## 15. Echter Minecraft-/NeoForge-Testserver

Die höchste Stufe verwendet die reale Modumgebung mit den produktiven Versionen von Minecraft, NeoForge, CC:Tweaked, Reactor-Mod und Mekanism.

Ziele:

- echter Installer
- echte Startup-Datei
- echte Computer und Modems
- echte Peripheral-Methoden
- echte Reactor-/Turbinen-/Matrixblöcke
- echte Tick- und Eventsemantik
- maschinenlesbarer Ergebnisbericht

Empfehlung:

- vorbereitete Testwelt oder NeoForge GameTest-Strukturen
- separater `gameTestServer`-Run
- fester Timeout
- Welt-, Log- und Report-Artefakte bei Fehlern
- PRs: kleiner Smoke-Test optional
- Nightly/Release: vollständiger Test verpflichtend

Der echte Server ersetzt die Simulation nicht. Die Simulation ist schneller und deterministisch; der Server erkennt Modellabweichungen und echte Mod-API-Unterschiede.

---

## 16. GitHub-Actions-Zielstruktur

Empfohlene Workflows:

```text
.github/workflows/
  ci-fast.yml
  ci-simulation.yml
  ci-nightly.yml
  ci-release.yml
  ci-remote-verify.yml
```

### `ci-fast.yml`

Bei jedem PR und Push:

- Repository-Integrität
- Syntax und Parse
- Manifest-/Release-Integrität
- alle nicht geskippten Unit-/Regressionstests
- Skip-Policy
- kleine deterministische Smoke-Szenarien

### `ci-simulation.yml`

Bei PRs und Merge-Kandidaten:

- kritische Safety-Szenarien
- Reactor-/Turbinen-Szenarien
- Kommunikations-Chaos
- Updatefehler
- Artefakte bei Fehlern

### `ci-nightly.yml`

Geplant:

- große Szenariomatrix
- lange Anlagenläufe
- Property-/Fuzztests
- Mutationstests
- vollständiges Trace-Replay
- echter GameTest-Server

### `ci-release.yml`

Nur nach erfolgreichen Required Checks:

- unveränderlichen Release-Kandidaten bauen
- Release-/Manifestmetadaten stempeln
- lokales Paket verifizieren
- realen Smoke-Test ausführen
- Deployment-Environment mit Schutzregeln
- Promotion auf `deploy/beta`

### `ci-remote-verify.yml`

Nach Promotion:

- veröffentlichtes Manifest laden
- jede veröffentlichte Datei laden
- Größe/Hash prüfen
- Remote gegen Kandidat vergleichen
- Pflichtpfade prüfen
- Deployment bei Fehler als ungültig markieren

### Workflow-Härtung

- `permissions: contents: read` als Standard
- nur benötigte Berechtigungen pro Job erhöhen
- externe Actions auf vollständige Commit-SHAs pinnen
- `timeout-minutes` für jeden Job
- `concurrency` mit Abbruch veralteter PR-Läufe
- Deployment-Concurrency ohne parallele Promotion
- feste oder kontrollierte Toolversionen
- Testreports und Fehlerartefakte hochladen
- Required Checks über Branch Rulesets erzwingen

---

## 17. Branch- und Release-Modell

Ziel:

```text
feature/* oder agent/*
        |
        v
Pull Request -> main
                  |
                  v
           geprüfter Commit
                  |
                  v
             deploy/beta
                  |
                  v
                Nodes
```

Regeln:

- keine direkten Pushes auf `main` oder `deploy/beta`
- `deploy/beta` enthält nur vollständig geprüfte Promotionen
- Nodes laden nur den Deployment-Ref oder unveränderlichen Commit
- Promotion ist serialisiert
- Rollback ist ein bewusstes Zurücksetzen auf einen bekannten geprüften Commit
- Remote-Verifikation läuft nach jeder Promotion

---

## 18. Diagnose und Artefakte

Bei Fehlern sollen automatisch bereitgestellt werden:

- JUnit-kompatibler Testreport
- Skip-Report
- Simulations-Seed
- Szenariodatei
- Eventtrace
- Modemtrace
- Peripheral-Call-Trace
- Invariantenverletzung mit erstem fehlerhaften Tick
- Node-Logs
- virtuelles Dateisystem
- verwendete Manifest-/Release-Metadaten
- bei GameTest: Serverlog und relevante Welt-/Strukturartefakte

Die CI-Ausgabe soll kurz bleiben; Detaildaten gehören in Artefakte.

---

## 19. Performance-Budgets

Die CI soll auch Zeitverhalten prüfen.

Beispielbudgets, zunächst als dokumentierte Baseline zu ermitteln:

- Heartbeat-Maximalabstand pro Rolle
- Control-Loop-Maximalabstand
- Discovery-Budget
- Matrix-Sampling-Budget
- maximale ausstehende Nachrichten
- maximale Retry-Anzahl
- maximale Lograte pro Fehlerklasse
- maximaler Simulationsfortschritt ohne Eventverarbeitung

Budgets müssen auf virtueller Zeit basieren, nicht auf der Geschwindigkeit des GitHub-Runners.

---

## 20. Dokumentationsregeln

Bei jeder CI-Änderung müssen geprüft werden:

- `CI_MASTER_PLAN.md`
- `CI_IMPLEMENTATION_BACKLOG.md`
- `TESTPLAN.md`
- `AGENTS.md`
- betroffene Workflow-Dateien
- betroffene Skip-Listen

Eine Aufgabe darf nur als abgeschlossen markiert werden, wenn:

- Code umgesetzt ist
- relevante Tests laufen
- kein kritischer Skip verbleibt
- Dokumentation den tatsächlichen Stand beschreibt
- der PR konkrete Validierungsergebnisse nennt

---

## 21. Interne Referenzen

### CI und Runner

- `.github/workflows/ci.yml`
- `tools/offline_validate.lua`
- `tools/run_lua_tests.sh`
- `tools/run_python_tests.sh`
- `tests/cc_env_shim.lua`
- `tests/known_failing_lua_tests.txt`
- `tests/known_failing_python_tests.txt`

### Manifest und Release

- `xreactor/manifest.lua`
- `xreactor/release.lua`
- `scripts/manifest_sync.py`
- `scripts/verify_remote_manifest.py`
- `tests/manifest_hash_size_guard_test.py`
- `tests/manifest_changed_files_guard_test.py`
- `tests/manifest_entrypoint_require_coverage_test.py`
- `tests/release_metadata_consistency_test.lua`

### Produktivadapter und Laufzeit

- `xreactor/adapters/reactor.lua`
- `xreactor/adapters/turbine.lua`
- `xreactor/nodes/rt/main.lua`
- `xreactor/nodes/rt/reactor_control.lua`
- `xreactor/nodes/rt/turbine_control.lua`
- `xreactor/master/main.lua`
- `xreactor/services/auto_update_service.lua`

### Projektregeln

- `AGENTS.md`
- `TESTPLAN.md`
- `README.md`
- `REWRITE_SPEC.md`
- `MIGRATION.md`

---

## 22. Externe Primärquellen

### CC:Tweaked

- Lua-/Cobalt-Kompatibilität: https://tweaked.cc/reference/feature_compat.html
- Breaking Changes und externe Peripherien: https://tweaked.cc/reference/breaking_changes.html
- `os`, Eventqueue und Timer: https://tweaked.cc/module/os.html
- `parallel` und Eventkopien: https://tweaked.cc/mc-1.21.y/module/parallel.html
- `modem_message`: https://tweaked.cc/event/modem_message.html
- Peripheral-Events: https://tweaked.cc/event/peripheral.html und https://tweaked.cc/event/peripheral_detach.html
- `settings` und `setting_changed`: https://tweaked.cc/module/settings.html
- HTTP-API: https://tweaked.cc/module/http.html
- Computer-Startup: https://tweaked.cc/reference/startup.html
- Dateisystem-API: https://tweaked.cc/module/fs.html

### GitHub Actions

- Workflow-Syntax, Matrix und Berechtigungen: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- Sicherer Einsatz und SHA-Pinning: https://docs.github.com/en/actions/reference/security/secure-use
- Concurrency: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- Deployment-Environments: https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments
- Deployment-Steuerung: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments

### NeoForge / reale GameTests

- GameTest-Framework: https://docs.neoforged.net/docs/misc/gametest/
- ModDevGradle Runs einschließlich `gameTestServer`: https://docs.neoforged.net/toolchain/docs/plugins/mdg/

Externe Mod-Peripherie-APIs müssen zusätzlich aus den im realen Modpack eingesetzten Versionen verifiziert und als versionierte Fixtures oder Links dokumentiert werden. CC:Tweaked weist ausdrücklich darauf hin, dass APIs externer Peripherie-Mods zwischen Versionen weniger stabil sein können.

---

## 23. Definition des Gesamtabschlusses

Der CI-Umbau ist erst abgeschlossen, wenn alle folgenden Aussagen wahr sind:

- Syntax-, Struktur-, Manifest- und Releaseprüfungen sind verpflichtend.
- kritische Tests werden nicht übersprungen.
- Skip-Wachstum wird automatisch verhindert.
- der echte Produktivcode läuft in der deterministischen CC-Simulation.
- Reactor, Turbine, Energy, Netzwerk und Updatepfad besitzen dynamische Modelle beziehungsweise realistische Fehlerprofile.
- Safety-Invarianten werden tickweise geprüft.
- reale Ingame-Traces können aufgezeichnet und wiedergegeben werden.
- Nightly führt Fuzz-, Chaos- und Mutationstests aus.
- ein echter Minecraft-/NeoForge-Testserver prüft mindestens Release-Kandidaten.
- CI und Deployment sind getrennt.
- nur vollständig geprüfte Commits werden an Nodes verteilt.
- das veröffentlichte Manifest und alle Remote-Dateien werden nach jeder Promotion verifiziert.

Bis dahin ist die CI als im Ausbau befindliches Sicherheitsnetz zu behandeln, nicht als Beweis vollständiger Ingame-Korrektheit.
