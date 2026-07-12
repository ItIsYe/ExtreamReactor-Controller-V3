# Coding-AI-Aufgaben: Installer- und Auto-Update-Audit

Stand: 2026-07-12  
Geprüfter Repository-Stand: `45db7c05a303aa3affbbca0b9aedf9c6110e208b`  
Ziel-Branch: `beta`

Diese Datei ergänzt:

- `docs/CODING_AI_IMPLEMENTATION_TASKS_2026-07-12.md`
- `docs/CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`
- `docs/CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`
- `docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md`

## Verbindliche Rahmenbedingungen

1. **Kein vollständiges Staging und kein vollständiges Backup der Installation.**
   - Die Single-Copy-Strategie bleibt wegen des begrenzten CC:Tweaked-Speichers bestehen.
   - Erlaubt sind kleine temporäre Dateien, ein kompakter Recovery-Bootstrap, ein kleiner Installationsmarker und ein kompaktes Backup der Konfigurationsdateien.

2. **Die RT-Safety darf durch ein Update nicht unkontrolliert ausfallen.**
   - Vor einem Update muss der laufende Node kontrolliert in einen definierten Update-/Safety-Zustand wechseln.

3. **Manifest, Installer und alle installierten Dateien müssen innerhalb eines Updateversuchs aus exakt demselben Source-Stand stammen.**

4. **`release.lua` darf erst nach vollständig erfolgreicher Installation als aktive Version gelten.**

5. **Ein Update darf niemals allein aufgrund eines erfolgreich ausgeführten `pcall(...)` als erfolgreich gelten.**
   - Erfolgreich bedeutet: Installer-Completion-Marker gesetzt, erwartete Dateien geprüft und installierte Version bestätigt.

---

# Kurzfassung der schwerwiegendsten Befunde

## P0

1. Manifest und Dateien können aus unterschiedlichen Commits stammen.
2. Der eigentliche Installationspfad prüft `size_bytes` und Lua-Syntax, aber nicht den im Manifest vorhandenen CRC32-Hash.
3. Der Root-Installer enthält unabhängige eingebettete Kopien der Installer-Module und einen zweiten Installationsablauf; mehrere Fixes aus `installer/init.lua` gelten dadurch nicht für den normalen Root-Installer-Pfad.
4. `/xreactor/config/remote_update.lua` wird nicht erhalten. Ein Update entfernt dadurch Token, Deaktivierung und benutzerdefiniertes Prüfintervall und legt danach wieder die unsichere Default-Konfiguration an.
5. `role.lua` und andere Preserves werden erst nach vollständigem Dateidownload wiederhergestellt. Ein Abbruch nach dem Löschen lässt den Node ohne Rolle zurück, obwohl der Testplan ausdrücklich das Gegenteil fordert.
6. `release.lua` kann in einer Teilinstallation bereits die neue Versionsnummer enthalten. Ein späterer Fehler kann dazu führen, dass der Updater die unvollständige Installation anschließend für aktuell hält.
7. Runtime und Installer laufen während des Auto-Updates parallel. Die Rollenlogik kann weiter Hardware steuern, Dateien schreiben oder Module nachladen, während `/xreactor` gelöscht und neu aufgebaut wird.
8. Mehrere kritische Schreib- und Löschvorgänge ignorieren Rückgabewerte und können trotz fehlender Config/Startup-Datei einen erfolgreichen Abschluss melden.

## P1

9. Alle Nodes prüfen und aktualisieren nahezu gleichzeitig. Dadurch entstehen GitHub-API-/Raw-Request-Spitzen und gleichzeitige Flotten-Reboots.
10. Jeder globale Manifest-Bump aktualisiert jede Rolle, selbst wenn sich ihr Dateisatz nicht geändert hat.
11. Command-Update, Auto-Update und Service-Wrapper verwenden mehrere voneinander abweichende Implementierungen.
12. Command-Updates können bei `shell.run()` einen normalen `false`-Rückgabewert als Erfolg behandeln.
13. `_G.__xreactor_remote_update` wird im Command-Update-Pfad nach Fehlern nicht sicher zurückgesetzt.
14. Standardmäßig ist Remote-Update ohne Token armed. In Verbindung mit fehlender Sender-Authentifizierung im Command-Protokoll ist das ein Sicherheitsrisiko.
15. Wiederholt fehlschlagende Updates besitzen keinen persistenten Circuit-Breaker und können die gesamte Flotte in eine Download-/Retry-Schleife bringen.

---

# INSTALL-P0.1 – Eine unveränderliche Source-ID pro Updateversuch

## Aktuelles Problem

Der Updatepfad löst mehrfach unabhängig voneinander einen Branch-SHA auf:

1. Auto-Updater prüft `release.lua` über einen SHA.
2. Auto-Updater lädt den Root-Installer über diesen SHA.
3. Der Root-Installer löst erneut einen SHA auf.
4. Das Manifest wird trotzdem vom beweglichen `beta`-Branch geladen.
5. Dateien werden im Root-Installer vom zuvor aufgelösten SHA geladen.

Der modulare Installer besitzt eine andere Mischstrategie:

- Manifest vom `beta`-Branch
- Dateien zunächst vom SHA
- Branch-Fallback nur bei Downloadfehler

Wenn eine SHA-Datei erfolgreich geladen wird, aber nicht zum neueren Branch-Manifest passt, wird dieselbe alte SHA-Datei erneut geladen. Ein Verify-Mismatch schaltet nicht auf den Branch-Fallback um.

Der Root-Installer lädt das Manifest außerdem zweimal. Zwischen beiden Downloads kann der Branch wechseln.

## Ziel

Zu Beginn eines Updateversuchs wird genau eine `source_id` bestimmt. Danach werden Installer, Manifest und alle Dateien ausschließlich aus dieser Quelle geladen.

## Verbindliche Strategie

### Bevorzugt: SHA-Modus

1. Branch-SHA einmal auflösen.
2. Root-Installer von diesem SHA laden.
3. Manifest von diesem SHA laden.
4. Alle Dateien von diesem SHA laden.
5. Installierte Metadaten speichern:

```lua
source_id = "<40-stelliger SHA>"
manifest_id = "manifest-v..."
```

### Fallback: Branch-Modus

Wenn SHA-Auflösung nicht möglich ist:

1. Den gesamten Versuch als `source_mode = "branch"` markieren.
2. Manifest und jede Datei ausschließlich von `beta` laden.
3. Kein per-Datei-Wechsel zwischen SHA und Branch.
4. Wechselt das Branch-Manifest während des Versuchs, Versuch abbrechen und vollständig neu beginnen.

## Nicht zulässig

- Manifest vom Branch und Dateien vom SHA
- Installer von SHA A, Manifest von Branch B und Dateien von SHA C
- SHA-Datei bei Verify-Mismatch wiederholt laden, ohne die Source-Strategie neu zu starten

## Tests

- Branch bewegt sich nach SHA-Auflösung: Update bleibt vollständig auf dem alten SHA und ist konsistent.
- SHA-Auflösung fällt aus: gesamter Versuch verwendet Branch.
- Manifest ändert sich mitten im Branch-Modus: kein gemischter Installationsstand.
- Manifest wird pro Versuch genau einmal geladen.

---

# INSTALL-P0.2 – CRC32 im tatsächlichen Installationspfad prüfen

## Aktuelles Problem

`installer/manifest.lua` besitzt `crc32()` und `is_current()`. `installer/stage.lua` verwendet diese Hash-Prüfung bei `install()` jedoch nicht.

`stage.verify()` prüft aktuell nur:

- Datei vorhanden
- Datei lesbar
- `size_bytes`
- Lua-Syntax bei `.lua`

Eine falsche oder beschädigte Datei mit identischer Länge wird akzeptiert.

## Ziel

Jede manifestierte Datei muss vor dem Commit oder spätestens vor dem erfolgreichen Abschluss gegen `entry.hash` geprüft werden.

## Umsetzung

Empfohlen:

```lua
function verify_content(content, entry)
  if entry.size_bytes and #content ~= entry.size_bytes then ... end
  if entry.hash and crc32(content):lower() ~= entry.hash:lower() then ... end
  if entry.path:sub(-4) == ".lua" then load(...) end
end
```

Reihenfolge:

1. Body im Speicher prüfen.
2. Erst nach erfolgreicher Size-/Hash-/Syntaxprüfung schreiben.
3. Nach Write optional nochmals Datei lesen und Hash bestätigen.

## Eingebettete Installer-Module

Solange es eingebettete Module gibt, müssen auch diese gegen das Manifest geprüft werden. Bevorzugt werden sie vollständig aus dem Root-Installer entfernt und automatisch aus den modularen Quellen generiert.

## Tests

- Inhalt gleicher Länge, aber anderes Byte: Installation muss mit `hash_mismatch` abbrechen.
- falscher Hash im Manifest: kein erfolgreicher Abschluss.
- eingebettete Datei weicht von Manifest ab: Guard muss fehlschlagen.

---

# INSTALL-P0.3 – Root-Installer und modulare Installerlogik konsolidieren

## Aktuelles Problem

Es existieren mindestens zwei vollständige Installationspfade:

1. `xreactor/installer/init.lua`
2. der eigenständige Ablauf im Root-Skript `installer`

Der Root-Installer enthält zusätzlich eingebettete Kopien von:

- `installer/http.lua`
- `installer/manifest.lua`
- `installer/stage.lua`
- `installer/ui.lua`
- `installer/auto_update.lua`
- `installer/init.lua`

Der normale manuelle und automatische Installationslauf verwendet den eigenständigen Root-Ablauf. Mehrere Verbesserungen der modularen `init.lua` gelten dort nicht oder anders.

## Aktuell bestätigte Unterschiede

### Startup-Recovery

Modulare `init.lua` schreibt eine Startup-Datei, die bei fehlendem `start.lua` ein `.xr_prev` zurückholen kann.

Der tatsächliche Root-Ablauf schreibt dagegen nur:

```lua
shell.run("/xreactor/start.lua")
```

### Optionale Features

Modulare `init.lua` serialisiert die aktuelle interaktive Auswahl erneut nach `config/optional_features.lua`.

Der Root-Ablauf installiert anhand der neuen In-Memory-Auswahl, stellt danach aber die alte Datei wieder her und persistiert die geänderte Auswahl nicht erneut.

### Dateireihenfolge

- modulare `init.lua`: Größe absteigend
- Root-Ablauf: alphabetisch

### Downloadstrategie

Der Root-Ablauf verwendet einen eigenen primitiven Downloader und keinen echten Branch-Fallback pro Source-Versuch.

## Ziel

Eine einzige Quellwahrheit.

## Bevorzugte Umsetzung

- Der Root-Installer ist nur ein kleiner Bootstrap.
- Er lädt einen versions-/SHA-gepinnten Installer-Kern.
- Die eigentliche Logik liegt ausschließlich in modularen Dateien.

Alternativ:

- Root-Datei wird deterministisch aus den modularen Quellen generiert.
- CI generiert sie neu und verlangt einen leeren Diff.
- Kein manuell gepflegter zweiter Ablauf.

## Abnahmekriterien

- Eine Änderung an `installer/stage.lua` gilt automatisch für manuellen und automatischen Installationslauf.
- Root-Installer besitzt keine unabhängige Preserve-/Download-/Startup-Logik.
- CI erkennt Drift.

---

# INSTALL-P0.4 – Gesamte Konfiguration erhalten

## Kritisches Auto-Update-Problem

Die Preserve-Liste enthält nicht:

```text
config/remote_update.lua
```

Folge bei jedem Update:

- `enabled = false` geht verloren
- `auto_update = false` geht verloren
- `check_interval_s` wird auf 120 zurückgesetzt
- `token` geht verloren
- Datei wird anschließend mit Defaultwerten und ohne Token neu angelegt

Das ist sowohl ein Funktions- als auch ein Sicherheitsfehler.

## Weitere verlorene Daten

Unter anderem können verloren gehen:

- rollenbezogene Configs
- Routingdateien
- Monitor-Konfigurationen
- Alert-State
- Layout-/UI-State
- zukünftige unbekannte Configdateien

## Ziel

Das gesamte Verzeichnis `/xreactor/config` wird erhalten, nicht nur eine kleine Allowlist.

## Crashfeste, speicherschonende Umsetzung

Vor dem Löschen:

1. Config rekursiv einlesen.
2. Zusätzlich als eine kompakte Recovery-Datei außerhalb von `/xreactor` speichern, zum Beispiel:

```text
/xreactor_recovery/config_backup.lua
```

3. Datei flushen und wieder einlesen/prüfen.
4. Erst dann `/xreactor` löschen.
5. Minimale Dateien sofort nach Erstellen des neuen Roots wiederherstellen:
   - `config/role.lua`
   - `config/remote_update.lua`
   - `config/node_id.txt`
6. Nach vollständiger Installation alle Configdateien wiederherstellen.
7. Nach erfolgreichem Abschluss Recovery-Datei entfernen.

Dies ist **kein vollständiges Installationsbackup** und erfüllt die Speicherbegrenzung.

## Denylist statt Allowlist

Falls einzelne Dateien nicht wiederhergestellt werden dürfen, explizite Denylist mit Begründung. Unbekannte zukünftige Configdateien müssen standardmäßig erhalten bleiben.

## Tests

- Token und deaktiviertes Auto-Update bleiben erhalten.
- unbekannte `future_feature.lua` bleibt erhalten.
- Abbruch unmittelbar nach Löschen: nächster Recovery-Lauf kennt Rolle und Update-Config.
- Stromausfall nach Config-Backup: Backup ist lesbar.

---

# INSTALL-P0.5 – Teilinstallation darf nicht als aktuelle Version gelten

## Problem

`release.lua` gehört zum normalen Dateisatz und kann vor Abschluss aller Dateien geschrieben werden.

Wenn danach eine Datei fehlschlägt, enthält der Computer möglicherweise bereits die neue `manifest_version`. Beim nächsten Check gilt die Teilinstallation dann als aktuell.

## Ziel

Die aktive Version wird erst nach vollständiger Prüfung veröffentlicht.

## Umsetzung

1. Während Installation Marker anlegen:

```text
/xreactor_recovery/update_state.lua
```

Beispiel:

```lua
return {
  state = "installing",
  target_manifest = "manifest-v386",
  source_id = "...",
  role = "RT",
  completed_files = 42,
  expected_files = 86,
}
```

2. `release.lua` und finaler Completion-Marker werden zuletzt geschrieben.
3. Nach allen Dateien:
   - Vollständigkeit prüfen
   - Hashes prüfen
   - Entry-Point vorhanden und parsebar
   - Rolle/Config vorhanden
   - installierte `manifest_id` entspricht Ziel
4. Erst dann:

```lua
state = "complete"
```

5. Boot prüft Marker. `installing` oder fehlender Completion-Marker startet Recovery statt normalen Node.

## Abnahmekriterien

- Fehler nach Installation von `release.lua` ist durch Reihenfolge nicht mehr möglich, da `release.lua` finalisiert wird.
- Teilinstallation wird nie als `up to date` eingestuft.
- Boot startet bei unvollständigem Marker den Recovery-Installer.

---

# INSTALL-P0.6 – Update und laufende Node-Logik koordinieren

## Aktuelles Problem

`start.lua` verwendet:

```lua
parallel.waitForAny(node_thread, auto_update_loop)
```

Findet der Auto-Updater eine neue Version, führt er den Installer innerhalb seiner Coroutine aus, während die Rollen-Coroutine weiterläuft.

Mögliche Folgen:

- Runtime schreibt Config/State während `/xreactor` gelöscht wird.
- Logger legt Verzeichnisse während Reinstall neu an.
- Lazy-`require()` kann während einer Teilinstallation fehlschlagen.
- Hardware-Regelung läuft während Dateisystem und Codebasis ersetzt werden.
- RT kann in einem nicht eindeutig definierten Zustand rebooten.

## Zielarchitektur

Der Auto-Update-Thread soll ein Update nur **anfordern**, nicht direkt installieren.

Ablauf:

1. Updater erkennt neue Version.
2. Er sendet lokalen Event/Status `update_requested`.
3. Start-Orchestrator fordert kontrolliertes Quiesce an.
4. Rolle bestätigt `ready_for_update`.
5. Rollenabhängige Vorbereitung:
   - RT: definierter Safety-/Hold-Zustand; Flow/Rods gemäß freigegebener Update-Safety-Policy
   - WATER/FUEL/REPROCESSOR: aktive Transfers sicher abschließen oder abbrechen, Ventile blockieren
   - LOG: Puffer flushen
   - MASTER: Commandqueue/Status abschließen
6. Rollenloop wird beendet.
7. Installer läuft allein.
8. Reboot.

## Timeout

Wenn Quiesce nicht bestätigt wird:

- kein blindes Löschen
- Update abbrechen
- Fehler an MASTER melden
- später erneut versuchen

## Tests

- Während Installation gibt es keine konkurrierenden Runtime-Schreibvorgänge.
- RT geht vor Update in definierten sicheren Zustand.
- aktiver Fuel-Transfer hinterlässt keine offenen Ventile.

---

# INSTALL-P0.7 – Jeder kritische Dateisystemvorgang muss geprüft werden

## Aktuelle Fehlerbilder

Mehrere Operationen ignorieren Erfolg/Fehler:

- Löschen von `/xreactor`
- Erstellen von `/xreactor`
- Restore der Preserves mit einfachem `fs.open`
- Schreiben von Rolle, optionalen Features, Auto-Update-Config und Startup

Ein fehlgeschlagener Restore kann still bleiben, anschließend wird trotzdem „Installation abgeschlossen“ gemeldet.

## Ziel

Keine kritische Operation ohne geprüften Rückgabewert.

## Anforderungen

- Nach Löschen prüfen, dass Root wirklich entfernt/leer ist.
- Nach `makeDir` prüfen, dass Verzeichnis existiert.
- Config-Restore über atomare Schreibfunktion.
- Jede Restore-Datei erneut lesen und vergleichen.
- `role.lua`, `remote_update.lua`, `start.lua`, `/startup.lua` sind Pflichtdateien.
- Fehler vor Completion-Marker hart abbrechen.

## Zusätzlich `stage.write()` härten

- Bei fehlgeschlagenem Backup-Move nicht die alte Datei löschen und blind weitermachen.
- Backup bis nach erfolgreicher Inhaltsprüfung behalten.
- Commit und Verify trennen:

```text
prepare_tmp -> verify_tmp -> move_old_to_prev -> move_tmp_to_target -> verify_target -> delete_prev
```

---

# INSTALL-P0.8 – Rolle und Manifest vor dem Löschen strikt validieren

## Rollenproblem

Eine vorhandene `role.lua` wird akzeptiert, solange `role` irgendein String ist. Eine unbekannte oder beschädigte Rolle kann dadurch eine Installation mit nur Basismodulen erzeugen und danach beim Boot scheitern.

## Manifestproblem

`load_remote()` akzeptiert grundsätzlich jedes Table. Es fehlen unter anderem Prüfungen für:

- erlaubte relative Pfade
- `..`/absolute Pfade
- doppelte Pfade
- gültige Größen/Hashes
- bekannte Rollen
- erwartete Entry-Points
- maximale Einzel-/Gesamtgröße
- Übereinstimmung Manifest/Release

## Ziel

Vor dem Löschen:

1. Rolle gegen feste Rollenliste prüfen.
2. Erwarteten Entry-Point bestimmen.
3. Manifest-Schema vollständig validieren.
4. Dateisatz für Rolle berechnen.
5. Jede Pflichtdatei muss Manifestmetadaten besitzen.
6. Gesamtgröße berechnen und Speicher-Preflight durchführen.
7. `release.lua` und Manifest müssen gleiche Version/ID/Source besitzen.

## Pfadsicherheit

Nur Pfade erlauben, die:

- nicht mit `/` beginnen
- kein `..`-Segment enthalten
- nach Normalisierung innerhalb `/xreactor` bleiben

---

# AUTO-P1.1 – Flottenweite Update-Stürme verhindern

## Problem

Jeder Node startet den ersten Check nach 30 Sekunden und danach standardmäßig alle 120 Sekunden. Alle Computer hinter derselben Server-IP greifen nahezu gleichzeitig auf GitHub zu.

Folgen:

- GitHub-API-Rate-Limit
- Raw-CDN-Spitzen
- viele parallele Vollinstallationen
- gleichzeitige Reboots
- gleichzeitiger Ausfall mehrerer Safety-/Support-Rollen

Ein einzelner API-Versuch pro Node löst das Flottenproblem nicht.

## Ziel

### Check-Jitter

```lua
initial_delay_s = 30 + deterministic_jitter(node_id, 0, 120)
check_interval_s = configured_interval + deterministic_jitter(node_id, -15, 15)
```

### Bevorzugt: Master-koordinierter Rollout

- MASTER prüft neue Version einmal.
- MASTER verteilt Zielversion/Source-ID.
- Nodes laden in Wellen.
- Nie alle RT-Nodes gleichzeitig.
- Kritische Rollen einzeln beziehungsweise redundanzbewusst aktualisieren.

### Fallback

Autonomer Check bleibt möglich, aber mit Jitter und persistentem Backoff.

---

# AUTO-P1.2 – Rollenbezogene Update-Digests

## Problem

Jeder globale `manifest_version`-Bump löst auf jeder Rolle einen kompletten Reinstall aus, auch wenn sich nur eine MASTER-Datei geändert hat.

## Ziel

Manifest enthält pro Rolle und Featureauswahl einen Digest, zum Beispiel:

```lua
role_digests = {
  MASTER = "...",
  RT = "...",
  ENERGY = "...",
}
```

Node vergleicht:

- eigene Rolle
- ausgewählte optionale Features
- erwarteten Dateisatz

Nur wenn sich dieser Digest ändert, ist ein Reinstall nötig.

Globale Bootstrap-/Installer-Sicherheitsänderungen dürfen über einen separaten `installer_generation`-Wert alle Nodes aktualisieren.

---

# AUTO-P1.3 – Persistenter Failure-Backoff und Circuit-Breaker

## Problem

Bei dauerhaftem Manifestfehler oder fehlendem Speicher versucht jeder Node regelmäßig erneut. Verschachtelte Retries können pro Check zahlreiche Downloads erzeugen.

## Ziel

Persistenter Status außerhalb `/xreactor`:

```lua
failure_count = 4
last_error = "hash_mismatch ..."
next_retry_ts = ...
target_manifest = "manifest-v386"
```

Empfohlener Backoff:

```text
1. Fehler: 5 min
2. Fehler: 15 min
3. Fehler: 1 h
weitere: 6 h oder manuelle Freigabe
```

Zurücksetzen bei:

- neuer Zielversion
- erfolgreichem Update
- manueller Recovery-Aktion

MASTER erhält Fehlerstatus und darf gezielten Retry auslösen.

---

# AUTO-P1.4 – Command-Update-Erfolg korrekt auswerten

## Probleme

### `shell.run()`

Folgendes ist nicht ausreichend:

```lua
local ok_run, result = pcall(shell.run, path)
if not ok_run then ... end
```

`pcall` kann erfolgreich sein, während `shell.run()` selbst `false` zurückgibt.

### Completion

Auch ein erfolgreich zurückgekehrtes `dofile()` beweist nicht, dass alle Dateien installiert wurden.

### ACK

Der Command-Pfad sendet derzeit vor der Installation ein ACK. Das bestätigt nur Annahme/Zustellung, nicht angewendetes Update.

## Ziel

Ergebnisstufen:

1. `ACCEPTED`
2. `QUIESCED`
3. `INSTALLING`
4. `REBOOTING`
5. nach Rückkehr `VERIFIED`
6. oder `FAILED` mit Reason-Code

Installer-Erfolg nur bei geprüftem Completion-Marker.

MASTER markiert Update erst als abgeschlossen, wenn der Node mit neuer Version zurückkehrt.

---

# AUTO-P1.5 – Remote-Update-Sicherheitsmodell härten

## Problem

Default-Konfiguration:

```lua
return {
  enabled = true,
  auto_update = true,
  check_interval_s = 120,
}
```

Es existiert standardmäßig kein Token. `enabled` armt sowohl lokale Updatefähigkeit als auch Command-Update. In Verbindung mit nicht vollständig authentifizierten Command-Absendern kann ein fremdes Paket ein Update auslösen.

## Ziel

Auto-Update und Remote-Command getrennt konfigurieren:

```lua
return {
  auto_update_enabled = true,
  remote_command_enabled = false,
  token = nil,
  trusted_master_ids = { "MASTER-1" },
}
```

Remote-Command nur, wenn:

- lokal ausdrücklich aktiviert
- Absender autorisiert
- Token/Authentifizierung gültig
- Replay-Schutz gültig

CRC32 ist nur Fehlererkennung, keine kryptografische Authentifizierung.

---

# AUTO-P1.6 – Updater-Implementierungen konsolidieren

## Aktuell vorhandene Varianten

- `installer/auto_update.lua` – tatsächlich von `start.lua` genutzt
- `core/auto_update.lua`
- `services/auto_update_service.lua`
- `core/remote_update.lua` mit eigener Versions- und Auto-Check-Logik

Sie unterscheiden sich bei:

- Intervallen
- HTTP sync/async
- Retries
- Cache-Busting
- Speicher-Reclaim
- Completion-Auswertung
- globalem Remote-Update-Flag
- Logging

Vergangene Fix-Kommentare zeigen, dass Fehler häufig nur in einer Kopie behoben wurden.

## Ziel

Ein gemeinsamer Update-Kern:

```text
update/source_resolver.lua
update/version_check.lua
update/installer_runner.lua
update/state_store.lua
update/orchestrator.lua
```

Auto-Check und Command-Update verwenden denselben Runner und dieselben Sicherheits-/Completion-Regeln.

---

# AUTO-P1.7 – Globales Remote-Update-Flag immer zurücksetzen

## Problem

Der aktive `installer/auto_update.lua` setzt `_G.__xreactor_remote_update` nach `dofile()` wieder zurück.

`core/remote_update.lua` setzt das Flag, räumt es bei Fehler/Rückkehr jedoch nicht zuverlässig auf.

## Ziel

`finally`-Semantik:

```lua
_G.__xreactor_remote_update = true
local ok, result = xpcall(run_installer, handler)
_G.__xreactor_remote_update = nil
```

Das Flag muss bei Erfolg, Fehler und abgebrochenem Installer zurückgesetzt werden, sofern kein Reboot stattgefunden hat.

---

# AUTO-P2.1 – Async-HTTP-Annahme und späte Responses behandeln

## Problem

`http_get_async()` prüft nur, ob `http.request()` geworfen hat. Der eigentliche Rückgabewert der Request-Annahme wird nicht ausgewertet.

Zusätzlich kann nach lokalem 15-Sekunden-Timeout später noch ein `http_success` eintreffen. Der Response-Handle wird dann möglicherweise von keinem Updater mehr geschlossen.

## Ziel

- Rückgabewerte von `http.request()` entsprechend der eingesetzten CC:Tweaked-Version prüfen.
- Abgelehnte Request sofort als Fehler behandeln.
- späte Success-/Failure-Events für abgelaufene URLs erkennen und Response schließen.
- optional Request-IDs/URL-Generation verwenden.
- Timer nach erfolgreicher Antwort nicht als aktiven Request behandeln.

---

# AUTO-P2.2 – Unbekannte lokale Version als Recovery-Fall behandeln

## Problem

Fehlt oder bricht `release.lua`, wird Auto-Update nur übersprungen:

```text
Lokale Version unbekannt
```

Gerade nach einer Teilinstallation wäre ein Recovery-Versuch notwendig.

## Ziel

- Completion-Marker prüfen.
- lokale Version unbekannt + armed + Recovery-Marker vorhanden → Recovery-Installer.
- lokale Version unbekannt ohne Recovery-Marker → klare Diagnose und kontrollierte manuelle/MASTER-Freigabe, kein blindes automatisches Löschen.

---

# TEST-P0 – Test- und CI-Lücken

## TEST-P0.1 `manifest_changed_files_guard_test.py` ist auf cleanen CI-Commits wirkungslos

Der Test verwendet ausschließlich:

```bash
git status --porcelain
```

In CI ist der ausgecheckte Commit normalerweise sauber. Bereits committed geänderte Dateien erscheinen daher nicht, und der Guard kann ohne Prüfung grün werden.

## Fix

Eine der Varianten:

1. immer alle Manifestdateien gegen Größe/CRC prüfen
2. oder Diff gegen Merge-Base/Base-Branch auswerten

Bevorzugt ist die vollständige Prüfung aller manifestierten Dateien; bei ungefähr 166 Dateien ist dies im CI problemlos.

---

## TEST-P0.2 Installer-Dateien sind nicht vollständig als kritische Shipment-Dateien abgesichert

Die aktuelle Critical-Liste konzentriert sich hauptsächlich auf MASTER-UI-Dateien. Ergänzen:

- Root `installer`
- alle `xreactor/installer/*.lua`
- `start.lua`
- `release.lua`
- `manifest.lua`
- `core/remote_update.lua`
- tatsächlich verwendeter Auto-Updater

---

## TEST-P0.3 Root-/Modul-Drift-Guard

Falls Root weiterhin eingebettet bleibt:

- eingebettete Blöcke extrahieren
- bytegenau mit modularen Dateien vergleichen
- Root-Ablauf darf keine unabhängige zweite Businesslogik besitzen

Besser: Root automatisch generieren und `git diff --exit-code` prüfen.

---

## TEST-P0.4 Pflicht-Fehlerszenarien

1. Manifest neuer als aufgelöster SHA
2. Branch bewegt sich mitten im Update
3. gleiche Dateigröße, falscher Hash
4. Stromausfall direkt nach Config-Backup
5. Stromausfall direkt nach Löschen von `/xreactor`
6. Fehler vor `release.lua`-Finalisierung
7. Fehler nach 90 % der Dateien
8. Restore von `remote_update.lua` schlägt fehl
9. unbekannte Rolle in `role.lua`
10. zu wenig Speicher vor Delete
11. zu wenig Speicher während Write
12. Command-Update via `shell.run()` gibt `false` zurück
13. Installer kehrt ohne Completion-Marker zurück
14. 20 Nodes erkennen gleichzeitig Update
15. drei aufeinanderfolgende fehlgeschlagene Zielversionen

---

# Testplan-Widersprüche, die bereinigt werden müssen

Der aktuelle `TESTPLAN.md` behauptet unter anderem:

1. `role.lua` werde auch dann erhalten, wenn der restliche Installationslauf fehlschlägt.
   - Tatsächlich erfolgt Restore erst nach erfolgreichem Download aller Dateien.

2. Im Update-Check gebe es keinen `api.github.com`-Call mehr.
   - Der aktive Auto-Updater ruft weiterhin die Branch-API zur SHA-Auflösung auf.

3. Die Strategie sei beta-only ohne verdecktes Pinning.
   - Installer und Updater verwenden weiterhin SHA-Pinning plus Branch-Mischung.

4. Size/Hash-Konsistenz sei Installerschutz.
   - Der tatsächliche `stage.verify()`-Pfad prüft keinen Hash.

5. Der Testplan bezeichnet sich als v358, während der Release-Stand v385 ist.

Dokumentation erst nach Festlegung der neuen Source-Strategie aktualisieren.

---

# Empfohlene Bearbeitungsreihenfolge

1. INSTALL-P0.1 Source-Pinning vereinheitlichen
2. INSTALL-P0.2 echte Hash-Prüfung
3. INSTALL-P0.4 vollständiges, crashfestes Config-Preserve
4. INSTALL-P0.5 Completion-Marker und `release.lua` zuletzt
5. INSTALL-P0.8 Manifest-/Rollen-/Speicher-Preflight
6. INSTALL-P0.7 alle Writes/Restores prüfen
7. INSTALL-P0.6 kontrolliertes Quiesce vor Installation
8. INSTALL-P0.3 Root-Installer konsolidieren/generieren
9. AUTO-P1.6 Updater-Kerne zusammenführen
10. AUTO-P1.4 Completion/ACK korrekt auswerten
11. AUTO-P1.7 Remote-Flag-Finally
12. AUTO-P1.1 Jitter und koordinierter Rollout
13. AUTO-P1.3 Failure-Backoff/Circuit-Breaker
14. AUTO-P1.2 Rollen-Digests
15. AUTO-P1.5 Security-Härtung
16. TEST-P0 vollständig umsetzen
17. Dokumentation/Testplan angleichen

# Definition of Done

- ein Updateversuch verwendet genau eine Source-ID
- Manifest und alle Dateien stammen aus derselben Source
- jede manifestierte Datei wird auf Größe, CRC32 und Lua-Syntax geprüft
- gesamte Config inklusive Remote-Update-Token bleibt erhalten
- Config-Recovery überlebt einen Stromausfall nach dem Delete
- `release.lua` wird erst nach vollständigem Erfolg aktiviert
- unvollständige Installation startet Recovery statt normalen Node
- Runtime ist während Dateiersetzung kontrolliert beendet/quiesced
- keine ignorierten kritischen FS-Schreibfehler
- Root-Installer und modulare Logik können nicht mehr driften
- Auto- und Command-Update nutzen denselben Installer-Runner
- Remote-Update-Flag wird zuverlässig zurückgesetzt
- kein fleetweiter gleichzeitiger Update-Sturm
- wiederholte Fehler führen zu persistentem Backoff
- CI prüft alle Manifestdateien und echte committed Diffs
- keine vollständige zweite Installation oder vollständiges Backup erforderlich
