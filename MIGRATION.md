# Migration Guide (aktueller Repo-Stand)

## Ziel
Diese Migration beschreibt den **aktuellen Installer- und Repo-Stand** für ExtreamReactor-Controller-V3 auf dem `beta`-Branch.

Wichtig:
- Der normale Installer-Lauf ist **beta-only**.
- Der Installer arbeitet mit **remote geladenen Metadaten** (`release.lua`, `manifest.lua`) vom `beta`-Branch und mit **lokaler Stage/Activate-Logik** auf dem Zielsystem.
- Commit-Pinning ist im normalen `beta`-Installerpfad **nicht erlaubt**.

---

## Aktueller Install-/Update-Flow

### Neuinstallation
1. Root-Installer `installer` lokal starten.
2. Rolle wählen.
3. Der Installer lädt:
   - `release.lua` vom `beta`-Branch
   - danach `manifest.lua` vom `beta`-Branch
4. Danach werden die erwarteten Dateien nach `/xreactor_stage` geladen.
5. Die Stage wird validiert.
6. Aktivierung/Commit:
   - aktives `/xreactor` -> `/xreactor_backup_prev`
   - `/xreactor_stage` -> `/xreactor`
   - Backup wird nach erfolgreichem Commit gelöscht
7. Optional `reboot`, damit alle Dienste sauber neu starten.

### Update
1. Root-Installer `installer` lokal starten.
2. `Update` wählen.
3. Rolle wird aus bestehender Konfiguration gelesen.
4. Der Installer lädt:
   - `release.lua` vom `beta`-Branch
   - `manifest.lua` vom `beta`-Branch
5. Dateien werden nach `/xreactor_stage` geladen und validiert.
6. Bestehende Config aus `/xreactor/config` wird ins Stage übernommen.
7. Aktivierung/Commit wie oben.
8. Optional `reboot`.

---

## Wichtige Strategie-Regeln

### 1. Beta-only bedeutet: kein Commit-Pin
Im normalen Installerlauf gilt:

- `release.lua.commit_sha` darf **kein echter Commit-SHA** sein
- `release.lua.source_ref` muss zu `beta` passen
- `manifest.lua.source_ref` muss zu `beta` passen

Wenn `release.lua` einen echten Commit-Pin enthält, ist das ein Fehler im Repo-Stand und der Installer **soll hart abbrechen**.

### 2. Remote-Metadaten, lokaler Commit
Der Installer ist **nicht lokal-only** im Sinne der Quelle:
- Metadaten und Dateien werden vom `beta`-Branch geladen
- Stage/Backup/Activate passieren lokal auf dem Zielsystem

Die lokale Aktivierung bleibt absichtlich getrennt von der Remote-Beschaffung.

### 3. Manifest ist verbindlich
Alle shipped Dateien im Installerpfad werden gegen `manifest.lua` validiert:
- `size_bytes`
- `hash`

Wenn eine Datei im Repo geändert wird, **muss** der passende Manifesteintrag nachgezogen werden.

---

## Was beim Update erhalten bleibt
- Rolle (`/xreactor/config/role.lua`)
- bestehende Runtime-Config in `/xreactor/config/*`
- persistierte Node-ID (`/xreactor/config/node_id.txt`)
- `/startup`, sofern ein nicht-XReactor-Startup absichtlich geschützt ist

---

## Aktueller RT-Hinweis
RT ist **nicht** mehr als „unverändert/frozen“ zu betrachten.

Der aktuelle Repo-Stand enthält bereits RT-Kompatibilitäts- und Migrationslogik, z. B. für Legacy-Konfigpfade:
- `runtime_ctx.monitor`
- `runtime_ctx.mon`
- Migration auf `monitor`

Das bedeutet:
- RT ist ein aktiver Stabilisierungsbereich
- RT-bezogene Änderungen müssen immer gegen aktuellen Bootpfad, Config-Schema und `ctx`-Contracts geprüft werden
- Änderungen an `xreactor/nodes/rt/*` brauchen besondere Vorsicht, weil Folgeblocker oft erst zur Laufzeit sichtbar werden

---

## Aktuelle Config-/Schema-Regeln (RT)
Für RT gilt aktuell:

- Monitor-Konfiguration soll über den **aktuellen gültigen Config-Pfad** laufen
- alte verschachtelte Legacy-Pfade dürfen nur noch als Kompatibilitätsmigration behandelt werden
- `config_normalizer.lua` ist der zentrale Ort für Legacy-Mapping und Default-/Clamp-Logik
- `main.lua` darf sich nicht auf alte Felder verlassen, die weder in `config.lua` noch im Normalizer garantiert werden

---

## Manifest-/Release-Disziplin
Ab diesem Stand gilt verbindlich:

1. Datei geändert -> Manifest prüfen
2. Dateiinhalt geändert -> `size_bytes` und `hash` nachziehen
3. `release.lua`, `manifest.lua` und `installer_main.lua` dürfen sich strategisch nicht widersprechen
4. Beta-only-Policy darf nicht durch Release-Metadaten ausgehebelt werden
5. Ein grüner Text-/Snippet-Test reicht nicht; semantische Guards sind Pflicht

---

## Codex-Arbeitsregeln für dieses Repo
Hinweis:
Dieser Abschnitt ist als **Repo-Arbeitsregel zur Fehlervermeidung** formuliert. Er ist **kein wörtliches Zitat offizieller OpenAI-Dokumentation**.

Bei Codex-/Agentenläufen in diesem Repo gilt:

1. **Immer aktuellen Stand lesen, bevor geändert wird**
   - betroffene Dateien zuerst vollständig lesen
   - bei Installer-/Manifest-Themen immer zusammen prüfen:
     - `installer`
     - `xreactor/installer_main.lua`
     - `xreactor/release.lua`
     - `xreactor/manifest.lua`

2. **Kleine, gezielte Änderungen statt breiter Refactors**
   - nur den konkreten Blocker und direkt angrenzende Schutzmechanismen anfassen
   - keine unnötigen Umbenennungen
   - keine Architekturänderungen auf Verdacht

3. **Nach jeder shipped Datei Manifest-Konsistenz prüfen**
   - wenn eine manifestierte Datei geändert wurde:
     - Größe neu prüfen
     - Hash neu prüfen
     - Manifest aktualisieren

4. **Semantische Tests vor Text-/Snippet-Tests**
   - nicht nur prüfen, ob eine Fehlermeldung als String existiert
   - echte Inhalte prüfen:
     - lädt `release.lua` als Tabelle?
     - passt `manifest.lua` zu echten Dateien?
     - existieren benötigte Modulpfade wirklich?
     - sind erwartete `ctx`-Felder/Funktionen wirklich vorhanden?

5. **Legacy-Migrationen zentral halten**
   - Altpfade nicht an vielen Stellen flicken
   - zentrale Migration im Normalizer/kompatiblen Adapter
   - Aufrufer danach auf das aktuelle Schema umstellen

6. **Bootpfad komplett denken**
   - nicht nur den ersten sichtbaren Crash reparieren
   - immer den direkt nächsten offensichtlichen Folgeblocker mitprüfen:
     - Require-Pfade
     - Config-Schema
     - `ctx`-Contract
     - Manifest-Coverage
     - Release-/Installer-Policy

7. **Beta-only wirklich durchhalten**
   - keine verdeckten Commit-Pins
   - keine Mischstrategie aus Branch und festen Commits im normalen Installerlauf

---

## Pfade

### Installer-relevant
- Install root: `/xreactor`
- Stage root: `/xreactor_stage`
- Backup root: `/xreactor_backup_prev`
- Installer-Logs:
  - `/xreactor_logs/installer_bootstrap.log`
  - `/xreactor_logs/installer_<role>.log`

### Runtime-/Logging-Pfade
- Runtime-Logs unter `/xreactor_logs`
- Rollen-/Knoten-bezogene Runtime-Dateien unter `/xreactor/config/*`

---

## Verbindliche Prüfliste vor Freigabe
Vor jedem als „fertig“ betrachteten Repo-Stand:

1. `release.lua` passt zur beta-only-Strategie
2. `manifest.lua.source_ref` passt zu `beta`
3. Installer-Policy, Release-Metadaten und Manifest widersprechen sich nicht
4. alle geänderten manifestierten Dateien haben korrekte `size_bytes` und `hash`
5. RT-Bootpfad wurde auf offensichtliche Folgeblocker mitgeprüft
6. vorhandene Guards/Tests sind semantisch ausreichend
7. Installer-Logs bleiben klar nach Rolle benannt

---

## Abschlussbewertung dieses Dokuments
Dieses Dokument beschreibt:
- den aktuellen beta-only-Installeransatz
- die lokale Stage/Activate-Logik
- die aktuelle Manifest-/Release-Disziplin
- die aktuellen Repo-Arbeitsregeln zur Fehlervermeidung

Es ersetzt ältere Annahmen wie:
- „lokal-only“ als Beschaffungsmodell
- „RT bleibt unverändert“
- rein textbasierte Schutztests als ausreichende Absicherung
