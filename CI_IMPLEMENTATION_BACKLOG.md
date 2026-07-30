# CI Implementation Backlog

> **Gehört zu:** [CI_MASTER_PLAN.md](CI_MASTER_PLAN.md)  
> **Status:** verbindliche Umsetzungsreihenfolge  
> **Arbeitsregel:** keine spätere Phase vorziehen, wenn dadurch ein paralleler oder toter Testpfad entsteht

Dieses Dokument ist für Maintainer und Coding-Agenten gedacht. Jede Phase ist bewusst klein genug, um als eigener Pull Request umgesetzt, getestet und reviewed zu werden.

---

## Arbeitsregeln für Coding-Agenten

Vor jeder Änderung:

1. `AGENTS.md` lesen.
2. `CI_MASTER_PLAN.md` lesen.
3. diese Backlog-Datei lesen.
4. alle betroffenen Runner, Tests und Produktivmodule vollständig lesen.
5. bestehende Tests und Hilfen wiederverwenden, bevor neue Parallelstrukturen angelegt werden.

Für jeden PR:

- genau eine Phase oder ein klar abgegrenztes Teilpaket
- keine stillen Semantikänderungen
- keine produktive Steuerungslogik im Simulator duplizieren
- keine neue Skip-Ausnahme ohne Issue, Ablaufdatum und Begründung
- Dokumentation auf den tatsächlichen Stand aktualisieren
- im PR angeben: ausgeführte Checks, verbleibende Grenzen, neue Artefakte

---

# Phase 0 — Baseline sichern und falsches Grün verhindern

**Priorität:** P0  
**Ziel:** Die bestehende CI wird ehrlich, bevor neue Simulationstechnik hinzukommt.

## 0.1 Testinventar erzeugen

### Aufgaben

- Skript `tools/list_tests.py` oder gleichwertig erstellen.
- alle `tests/*_test.lua` und `tests/*_test.py` erfassen.
- Status aus den Skip-Listen zuordnen.
- Ausgabe als Text und JSON ermöglichen.
- pro Fachbereich zählen.

### Pflichtausgabe

- Gesamtzahl Lua
- Gesamtzahl Python
- ausgeführt
- geskippt
- unbekannt
- kritische Skips
- Kategorien

### Definition of Done

- CI schlägt fehl, wenn keine Tests gefunden werden.
- CI schlägt fehl, wenn ein Test weder ausgeführt noch bewusst klassifiziert wird.
- JSON-Report wird als Artefakt gespeichert.

## 0.2 Skip-Format ersetzen

### Aufgaben

Flache Textlisten in ein maschinenlesbares Format überführen, zum Beispiel TSV:

```text
path	category	issue	owner	added	expires	release_blocking	reason
```

### Regeln

- keine leeren Pflichtfelder
- Ablaufdatum zwingend
- `release_blocking=true` für kritische Domänen
- unbekannte Kategorie = Fail
- abgelaufen = Fail
- neuer Skip ohne explizite Baseline-Aktualisierung = Fail

### Definition of Done

- Runner lesen nur noch das neue Format.
- aktuelle Einträge sind vollständig migriert.
- kritische Skips werden in einem separaten roten Report ausgewiesen.

## 0.3 Skip-Budget-Guard

### Aufgaben

- Baseline-Datei mit erlaubten Maximalzahlen anlegen.
- Gesamtzahl darf nicht steigen.
- kritische Kategorien dürfen nicht steigen.
- PR-Kommentar oder Job-Summary mit Delta erzeugen.

### Definition of Done

- ein absichtlich hinzugefügter Skip macht die CI rot.
- das Entfernen eines Skips aktualisiert die Baseline kontrolliert.

## 0.4 Aktuelle Workflow-Grenzen dokumentieren

### Aufgaben

- `TESTPLAN.md` aktualisieren.
- veraltete v358- und monolithische-Installer-Aussagen korrigieren.
- Pflichtchecks und aktuelle Skips sichtbar markieren.

### Definition of Done

- kein dokumentierter Pflichtcheck ist gleichzeitig still geskippt.

---

# Phase 1 — bestehende Fast-CI härten

**Priorität:** P0/P1  
**Ziel:** Syntax, Struktur, Manifest und Release werden zuverlässige Required Checks.

## 1.1 Workflow in unabhängige Jobs aufteilen

Empfohlene Jobs:

- `repository-integrity`
- `lua-parse`
- `python-static`
- `manifest-integrity`
- `release-integrity`
- `lua-tests`
- `python-tests`
- `skip-policy`

### Definition of Done

- ein früher Fehler verhindert nicht die Diagnose der anderen unabhängigen Jobs.
- jeder Job hat `timeout-minutes`.
- jeder Job hat eine eindeutige Required-Check-Bezeichnung.

## 1.2 Workflow-Berechtigungen minimieren

### Aufgaben

- Workflow-Default:

```yaml
permissions:
  contents: read
```

- Berechtigungen nur in Deploymentjobs erhöhen.

### Definition of Done

- Testjobs benötigen keine Schreibrechte.

## 1.3 Concurrency ergänzen

### Aufgaben

- veraltete PR-Läufe abbrechen.
- Deploymentläufe niemals parallel ausführen.

### Definition of Done

- neuer Commit im selben PR beendet den alten Testlauf.
- zwei Promotionen können nicht gleichzeitig laufen.

## 1.4 Actions pinnen

### Aufgaben

- alle externen Actions auf vollständige Commit-SHAs pinnen.
- Kommentar mit lesbarer Upstream-Version ergänzen.
- Updateprozess dokumentieren.

### Definition of Done

- keine externe Action wird nur über bewegliches Tag referenziert.

## 1.5 Toolversionen kontrollieren

### Aufgaben

- Lua-Version explizit festlegen.
- Python-Version explizit festlegen.
- Runner-Abhängigkeiten dokumentieren.
- möglichst Container oder Setup-Schritte mit reproduzierbaren Versionen verwenden.

### Definition of Done

- CI-Ausgabe zeigt tatsächlich verwendete Versionen.

---

# Phase 2 — Manifest- und Releasegate reparieren

**Priorität:** P0  
**Ziel:** Kein inkonsistenter oder unvollständiger Stand kann veröffentlicht werden.

## 2.1 Changed-Files-Guard korrigieren

### Aufgaben

`tests/manifest_changed_files_guard_test.py` von `git status --porcelain` auf echten Commitvergleich umstellen.

Unterstützte Modi:

- `--base <sha> --head <sha>`
- automatische Ermittlung aus GitHub-Umgebung
- lokaler Fallback gegen Merge-Base

### Testfälle

- manifestierte Datei geändert, Manifest unverändert -> Fail
- nur nicht manifestierte Doku geändert -> Pass
- manifestierte Datei und Manifest korrekt geändert -> Pass
- Rename einer manifestierten Datei -> Fail bis Manifest angepasst
- Datei gelöscht, Manifesteintrag bleibt -> Fail

### Definition of Done

- Test funktioniert in sauberem Checkout.
- Workflow checkt ausreichende Git-Historie aus.

## 2.2 Release-Metadaten vereinheitlichen

### Aufgaben

- festlegen, welche Felder verbindlich sind.
- `xreactor/release.lua`, Generatoren und Tests angleichen.
- `release_metadata_consistency_test.lua` reparieren.
- Test aus Skip-Liste entfernen.

### Pflichtfelder

- Release-ID
- Manifest-ID
- Manifestversion
- Manifestdateianzahl
- Hashalgorithmus
- Source-Ref oder Commit
- Installer-Größe und -Hash, falls weiterhin verwendet

### Definition of Done

- Test ist verpflichtend und grün.
- absichtliche Abweichung eines Feldes macht ihn rot.

## 2.3 Versions-Bump-Guard

### Aufgaben

- ausgelieferte Codeänderungen erkennen.
- prüfen, dass Manifest- und Releaseversion erhöht wurden.
- reine Dokuänderungen ausnehmen.
- Rückwärtsversion verhindern.

### Definition of Done

- Verhalten ändern ohne Bump -> Fail.
- Doku-only -> kein unnötiger Bump.

## 2.4 Manifestgenerator bereinigen

### Aufgaben

- doppelte Flags wie mehrfaches `always=true` verhindern.
- Headerkommentar automatisch aktuell halten oder entfernen.
- kanonische Formatierung erzwingen.
- Generator idempotent machen.

### Definition of Done

- zweimaliges Generieren erzeugt keinen Diff.
- doppelte Pfade/Flags werden vor dem Schreiben abgelehnt.

## 2.5 Remote-Verifikation als Workflow

### Aufgaben

- `ci-remote-verify.yml` anlegen.
- nach Promotion ausführen.
- `scripts/verify_remote_manifest.py` verwenden.
- Report als Artefakt speichern.

### Definition of Done

- absichtlich falsche Remote-Datei erzeugt Fail.
- fehlender Pflichtpfad erzeugt Fail.

---

# Phase 3 — kritische bestehende Tests reaktivieren

**Priorität:** P0  
**Ziel:** Sicherheitskritische Domänen haben keine Skips mehr.

Reihenfolge:

1. SAFE/SCRAM und Coolant
2. Turbinen-Overspeed
3. Reactor-Rod-Clamps
4. Shutdown/ACK
5. RT global hold und Sync
6. Energy Heartbeat/Topology
7. Installer/Update

Für jeden Test:

- aktuelle Produktivsemantik bestimmen
- prüfen, ob Test oder Code falsch ist
- `CONTENT_DRIFT` nicht automatisch als Testfehler behandeln
- reale Regression gegebenenfalls zuerst im Code beheben
- Test auf stabile öffentliche oder fachliche Schnittstelle ausrichten

### Definition of Done

- kein Release-blockierender Test steht in einer Skip-Liste.
- Testfehler liefern klare Ursache statt nur String-Mismatch.

---

# Phase 4 — Simulator-Kernel

**Priorität:** P1  
**Ziel:** relevante CraftOS-/CC:Tweaked-Semantik deterministisch bereitstellen.

## 4.1 Grundgerüst

Anlegen:

```text
tests/sim/cc/kernel.lua
tests/sim/cc/event_queue.lua
tests/sim/cc/scheduler.lua
tests/sim/cc/timers.lua
tests/sim/runner.lua
```

### Definition of Done

- virtuelle Zeit läuft ohne echte Sleeps.
- Endlosschleifen werden über Tick-/Step-Limit erkannt.
- jeder Lauf ist mit Seed reproduzierbar.

## 4.2 Eventqueue

### Unterstützen

- ungefiltertes und gefiltertes Pull
- Queue-Reihenfolge
- `terminate`
- primitive Werte und Tabellen
- getrennte Computerqueues

### Vertragstests

- Filter verwirft Events bis zum passenden Event.
- `pullEventRaw` behandelt `terminate` anders als `pullEvent`.
- `queueEvent` bewahrt unterstützte Werte.

## 4.3 Timer

### Unterstützen

- eindeutige IDs
- Cancel
- 0,05-s-Aufrundung
- mehrere Timer am selben Tick
- deterministische Reihenfolge

### Definition of Done

- offizielle CC:Tweaked-Beispiele verhalten sich im Simulator erwartungsgemäß.

## 4.4 Parallel

### Unterstützen

- `waitForAny`
- `waitForAll`
- Eventkopie pro Funktion
- Fehlerweitergabe
- Rückgabe bei erster/allen fertigen Funktionen

### Definition of Done

- getrennte Eventkopien sind durch Vertragstest bewiesen.
- bestehende Auto-Update-/Node-Parallelpfade können gestartet werden.

## 4.5 CraftOS-Basis

Ergänzen:

- `fs`
- `settings`
- `term`
- `monitor`
- `os.getComputerID`
- Label
- Reboot/Shutdown
- Startup
- HTTP-Eventmodell

### Definition of Done

- mindestens ein echter Rollen-Entrypoint bootet bis zu einem kontrollierten Wartezustand.

---

# Phase 5 — Modem- und Peripheral-Simulation

**Priorität:** P1

## 5.1 Peripheral Registry

### Unterstützen

- `isPresent`
- `getType`
- `getMethods`
- `call`
- `wrap`
- `find`
- Attach/Detach

### Definition of Done

- Discovery erkennt dynamisch hinzugefügte und entfernte Geräte.

## 5.2 Modembus

### Unterstützen

- offene Kanäle
- Reply-Kanal
- Distanz
- wired/wireless Profile
- mehrere Modems pro Computer
- Netzwerkpartitionen

### Fehlerprofile

- drop
- duplicate
- delay
- reorder
- corrupt
- disconnect

### Definition of Done

- MASTER und mindestens ein Node tauschen echte Produktivnachrichten aus.
- Fehlerprofil ist per Seed reproduzierbar.

## 5.3 HTTP- und Updatefehler

### Unterstützen

- Success
- HTTP-Fehler
- Timeout
- kaputte Antwort
- inkonsistenter Stand

### Definition of Done

- Auto-Updatepfad kann ohne echten Netzwerkzugriff getestet werden.

---

# Phase 6 — dynamische Anlagenmodelle

**Priorität:** P1/P2

## 6.1 Reactor

### Implementieren

- thermischer Zustand
- Rod-Wirkung
- Fuel/Waste
- Coolant/Steam
- aktive/inaktive Zustände
- API-Varianten
- Readback-Lag
- Setterfehler

### Kalibrierung

- zunächst einfache dokumentierte Gleichungen
- Parameter über Fixtures konfigurierbar
- später mit Ingame-Traces kalibrieren

### Definition of Done

- Reactor-Regler stabilisiert mindestens ein Referenzszenario.
- Safety-Fälle verletzen keine Invarianten.

## 6.2 Turbine

### Implementieren

- RPM und Trägheit
- Flow
- Coil
- Energieproduktion
- Overspeed
- Readback-Lag

### Definition of Done

- Ramp-up, Zielband und Overspeed sind über Zeit testbar.

## 6.3 Energy

### Implementieren

- gespeicherte Energie
- Kapazität
- Input/Output
- Ports und Identität
- langsame Aufrufe
- Topologieänderung

### Definition of Done

- bestehende Energy-Regressionsfälle laufen gegen das Modell.

---

# Phase 7 — Szenarien und Invarianten

**Priorität:** P1

## 7.1 Szenarioformat

- versionierte Lua- oder JSON-Struktur
- Topologie
- Seed
- Zeitlinie
- Fehlerprofile
- Invarianten
- maximale Laufzeit

## 7.2 Invariantenbibliothek

Anlegen:

```text
tests/sim/invariants/control.lua
tests/sim/invariants/safety.lua
tests/sim/invariants/comms.lua
tests/sim/invariants/update.lua
```

## 7.3 Pflicht-Suite

Mindestens:

- normaler Gesamtboot
- Nodes vor MASTER
- MASTER-Verlust
- Coolant pending/recovery/confirmed low
- Übertemperatur
- Turbinenoverspeed
- Readback-Lag
- ACK nach Retry
- Peripheral detach
- Energy-Sampling unter Last
- Updateabbruch und Recovery

### Definition of Done

- kritische Suite läuft in jedem PR.
- vollständige Suite läuft auf Merge-Kandidaten.
- Fehlerartefakte enthalten ersten verletzten Tick.

---

# Phase 8 — Trace Recorder und Replay

**Priorität:** P2

## 8.1 Ingame-Recorder

### Aufgaben

- Peripheral-Aufrufe instrumentieren
- Events protokollieren
- Modemnachrichten protokollieren
- Statuswechsel protokollieren
- Format versionieren
- Größe begrenzen

## 8.2 Replay

### Aufgaben

- Trace als Fixture laden
- Produktivcode mit aufgezeichneten Eingaben starten
- relevante Entscheidungen vergleichen
- tolerierbare Zeit-/Wertabweichungen explizit definieren

### Definition of Done

- mindestens ein realer Reactor-/Turbinenlauf ist reproduzierbar.
- mindestens ein historischer Fehler besitzt Trace-Fixture.

---

# Phase 9 — Property-, Chaos- und Mutationstests

**Priorität:** P2

## 9.1 Property-Tests

- Topologien generieren
- Ereignisse generieren
- Invarianten prüfen
- fehlerhafte Fälle minimieren

## 9.2 Chaos

- Netzwerk
- Peripherien
- HTTP
- Reboots
- langsame Methoden

## 9.3 Mutation

- kritische Operatoren und Guards mutieren
- pro Fachbereich Mutationsscore erfassen
- überlebende kritische Mutationen blockieren

### Definition of Done

- Seed und minimiertes Szenario werden als Artefakt gespeichert.
- kritische Referenzmutationen werden zuverlässig erkannt.

---

# Phase 10 — echter NeoForge-/Minecraft-Testserver

**Priorität:** P2/P3

## 10.1 Technischer Spike

Prüfen:

- exakte ATM10-/NeoForge-Version
- reproduzierbarer Serverstart
- Lizenz-/Redistributionsgrenzen des Modpacks
- GameTest-Registrierung
- Laden einer vorbereiteten Welt
- Ergebnisexport

## 10.2 Smoke-Suite

- Installer laden
- MASTER und RT booten
- Modemkommunikation
- Peripheral-Discovery
- ein Reactor-/Turbinenkommando
- Report schreiben

## 10.3 vollständige Release-Suite

- Safety
- Overspeed
- Neustart
- Update
- Energy

### Definition of Done

- Release-Kandidat erhält maschinenlesbaren Pass/Fail-Report.
- Serverlog wird bei Fehler hochgeladen.

---

# Phase 11 — Deployment trennen und absichern

**Priorität:** P0 vor produktiver Vollautomatisierung

## 11.1 Deployment-Ref

- `deploy/beta` oder gleichwertigen Ref einführen.
- Nodes auf Deploymentquelle umstellen.
- Entwickler arbeiten nicht direkt auf Deployment-Ref.

## 11.2 Promotion

- nur nach allen Required Checks
- serialisiert
- über geschütztes GitHub Environment
- unveränderlicher Commit als Quelle

## 11.3 Rollback

- bekannten geprüften Commit auswählen
- erneut promovieren
- Remote-Check ausführen
- Rollback sichtbar protokollieren

### Definition of Done

- fehlerhafter Commit auf Entwicklungsbranch erreicht Nodes nicht automatisch.
- Deployment ist eindeutig einem geprüften Commit zugeordnet.

---

# Phase 12 — Abschluss und Betrieb

## 12.1 Required Checks konfigurieren

Mindestens:

- repository-integrity
- syntax
- manifest-integrity
- release-integrity
- skip-policy
- critical-unit
- critical-simulation

## 12.2 Nightly-Betrieb

- vollständige Szenariomatrix
- Fuzz
- Mutation
- Trace-Replay
- GameTest

## 12.3 Wartung

- monatlich Skip-Ablauf prüfen
- externe API-Fixtures bei Modpackupdate erneuern
- Simulator gegen neue Ingame-Traces vergleichen
- Action-SHAs kontrolliert aktualisieren
- Performancebudgets beobachten

---

# Empfohlene PR-Aufteilung

1. `ci: add test inventory and skip policy`
2. `ci: split fast validation jobs`
3. `ci: fix manifest changed-files guard`
4. `ci: restore release metadata gate`
5. `tests: reactivate critical safety regressions`
6. `tests: add deterministic CC event kernel`
7. `tests: add timer and parallel contracts`
8. `tests: add modem and peripheral simulator`
9. `tests: add reactor and turbine plant models`
10. `tests: add critical scenario suite`
11. `tests: add trace recorder and replay`
12. `tests: add property and mutation testing`
13. `ci: add real game smoke workflow`
14. `release: separate tested deployment ref`

Jeder PR muss eigenständig grün sein und darf keine dauerhaft parallele alte/neue Testarchitektur zurücklassen.

---

# Agenten-Abschlusscheck

Vor dem Markieren einer Aufgabe als erledigt:

- [ ] Produktivcode wurde nicht in Tests kopiert.
- [ ] relevante bestehende Tests wurden ausgeführt.
- [ ] neue Tests scheitern nachweislich bei absichtlich eingebautem Fehler.
- [ ] keine kritischen Skips hinzugekommen.
- [ ] Fehlerausgabe ist reproduzierbar.
- [ ] Dokumentation entspricht dem echten Stand.
- [ ] Manifest/Release wurden nur geändert, wenn ausgelieferte Dateien betroffen sind.
- [ ] PR nennt konkrete Befehle und Ergebnisse.
- [ ] keine Behauptung „game-nah“ ohne belegten Simulator- oder Ingame-Test.
