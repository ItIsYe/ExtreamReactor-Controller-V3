# AGENTS.md

## Verbindliche CI-Unterlagen

Bei jeder Arbeit an CI, Tests, Simulator, Installer, Manifest, Release oder Deployment müssen vor der Änderung vollständig gelesen werden:

- [`CI_MASTER_PLAN.md`](CI_MASTER_PLAN.md) — kanonisches Zielbild, Sicherheitsregeln, Testarchitektur und Quellen
- [`CI_IMPLEMENTATION_BACKLOG.md`](CI_IMPLEMENTATION_BACKLOG.md) — verbindliche Reihenfolge und Definition-of-Done
- [`TESTPLAN.md`](TESTPLAN.md) — bestehende fachliche Regressionen und manuelle Szenarien

Für Coding-Agenten gilt zusätzlich:

- keine spätere Backlog-Phase vorziehen, wenn dadurch ein paralleler oder toter Testpfad entsteht
- keine Produktivlogik im Simulator kopieren; der Simulator stellt nur Umgebung und Peripherien bereit
- kein kritischer Skip ohne klar dokumentierten bekannten Fehler und Release-Blockade
- kein Abschlussstatus ohne tatsächlich ausgeführte Prüfungen
- CI-Härtung, Syntax-, Manifest- und Releasechecks bleiben erhalten; Game-Simulation ist eine zusätzliche Schicht

---

## Projektprinzipien

### 1. Verhalten und Stabilität zuerst
- Funktionierendes Verhalten ist wichtiger als schönere Struktur.
- Bestehende Logik darf nicht ohne klaren Grund verändert werden.
- Keine stillen Änderungen an zentralem Laufzeitverhalten, Zustandsübergängen, Sicherheitslogik oder kritischen Kontrollpfaden.
- Wenn Verhalten geändert werden muss, muss das ausdrücklich dokumentiert werden:
  - was geändert wurde
  - warum es nötig war
  - welches Risiko reduziert wurde

### 2. Keine Scheinarbeit
- Keine Dateien nur anlegen, damit die Struktur „moderner aussieht“.
- Keine Module behalten oder erzeugen, die nicht real im Hauptfluss genutzt werden.
- Keine künstliche Dateiverkleinerung ohne echten Architekturgewinn.
- Keine kosmetischen Umbenennungen ohne klaren Nutzen.

### 3. Kein unnötiger Big-Bang-Refactor
- Keine komplette Neuschreibung stabiler Bereiche.
- Bestehende robuste Logik soll bevorzugt verschoben und sauber integriert werden, nicht neu erfunden werden.
- Reale Integration ist wichtiger als mehr Dateien.

---

## Architekturprinzipien

### Zielbild
Die gewünschte Struktur ist möglichst klar getrennt in:

1. Runtime / Sampling
2. Status-Payload
3. UI-Modell
4. Rendering

Zusätzlich gilt:
- gemeinsame Basisbausteine sollen genutzt werden, wenn sie bereits existieren
- gemeinsame Support-Schichten sollen real im Hauptfluss genutzt werden
- `main.lua` soll möglichst Wiring / Bootstrap / Loop-Orchestrierung sein

### Modularisierung
- Verantwortlichkeiten sollen klar getrennt werden.
- Logik soll nur dann ausgelagert werden, wenn dadurch echte Wartbarkeit oder Klarheit entsteht.
- Keine Parallelpfade dauerhaft bestehen lassen, in denen alte und neue Architektur gleichzeitig aktiv sind.

---

## Bevorzugte Arbeitsweise

### Vor jeder Änderung
- Relevante Dateien und Abhängigkeiten vollständig lesen.
- Vorhandene Module prüfen, bevor neue angelegt werden.
- Prüfen, ob bereits eine passende Schicht oder Hilfsfunktion existiert.

### Während der Arbeit
- Verhaltenserhalt vor Strukturperfektion.
- Minimale, nachvollziehbare Schritte.
- Keine Doppelimplementierung alt/neu stehen lassen.
- Keine stillen Semantikänderungen.

### Wenn Unsicherheit besteht
- Test ergänzen
- Guard ergänzen
- Dokumentieren
- oder Änderung nicht durchführen

---

## Tests und Validierung

### Pflicht
Nach Änderungen müssen alle relevanten Prüfungen ausgeführt werden.

Dazu gehören je nach Scope:
- Regressionstests
- Parse-/Load-/Runtime-Guards
- Installer-Tests
- Architektur-/Struktur-Guards
- betroffene modul- oder node-spezifische Tests

### Bei Refactors zusätzlich
Es müssen gezielt Tests ergänzt werden, wenn sonst nicht belastbar nachweisbar ist, dass:
- Verhalten erhalten blieb
- neue Module real den Hauptfluss tragen
- Refactors keine versteckten Parallelpfade oder Doppelstrukturen erzeugen

---

## Dokumentation

Wenn der Codezustand oder der Abschlussstatus verändert wird, müssen bei Bedarf diese Dateien mitgepflegt werden:
- `README.md`
- `MIGRATION.md`
- `TESTPLAN.md`
- `CI_MASTER_PLAN.md`
- `CI_IMPLEMENTATION_BACKLOG.md`
- projektspezifische Closeout- oder Statusdokumente

Dokumentation darf nur echten Stand abbilden.
Keine Abschlussbehauptung ohne realen Audit-/Testlauf.

---

## Git-Regeln
- Finaler Zustand muss committed sein.
- Worktree muss sauber sein.
- Keine halbfertigen Umbauten zurücklassen.
- Keine toten Zwischenstrukturen liegen lassen, wenn sie nicht bewusst dokumentiert sind.

---

## Was ausdrücklich vermieden werden soll
- unnötige neue Modulwellen
- Schönheitsrefactors ohne Laufzeitnutzen
- unnötige Dateiumbenennungen
- Architekturarbeit ohne klaren Mehrwert
- Parallelpfade, in denen alte und neue Architektur gleichzeitig dauerhaft aktiv sind

---

## Abschlussregel
Wenn kein echter Blocker vorhanden ist, soll kein weiterer Umbau erfunden werden.

Dann gilt:
- minimale Korrekturen nur falls nötig
- sonst Abschluss dokumentieren
- klare JA/NEIN-Aussage zum Abschlussstatus treffen
