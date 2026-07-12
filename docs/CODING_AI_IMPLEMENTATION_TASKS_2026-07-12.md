# Coding-AI-Aufgaben aus dem Projekt-Audit

Stand: 2026-07-12  
Ziel-Branch: `beta`

## Zweck dieser Datei

Diese Datei beschreibt die beim Projekt-Audit gefundenen Verbesserungen so, dass eine Coding-KI sie nacheinander umsetzen kann. Jeder Punkt enthält Problem, Ziel, technische Hinweise und Abnahmekriterien.

## Verbindliche Rahmenbedingungen

1. **Kein vollständiges Stage-Verzeichnis und keine vollständige zweite Installation anlegen.**
   - Der Installer verwendet absichtlich `Delete + Reinstall`, weil auf CC:Tweaked-Computern zu wenig Festplattenspeicher für zwei vollständige Installationen vorhanden ist.
   - Frühere Stage-/Backup-Lösungen führten regelmäßig zu abgebrochenen Installationen wegen vollem Speicher.
   - Diese Entscheidung darf nicht ohne ausdrückliche Freigabe geändert werden.

2. **Keine vollständige Last-known-good-Kopie von `/xreactor` anlegen**, wenn sie ähnlich viel Speicher wie die Installation benötigt.
   - Ein kleiner Recovery-Bootstrap außerhalb von `/xreactor` ist erlaubt.
   - Kleine temporäre Dateien für den jeweils aktuellen Schreibvorgang bleiben erlaubt.

3. Bestehendes Laufzeitverhalten der Reaktor- und Turbinenregelung darf nicht unbeabsichtigt verändert werden.

4. Änderungen an manifestierten Dateien müssen immer mit einer Aktualisierung von `xreactor/manifest.lua` und `xreactor/release.lua` sowie den vorhandenen Manifest-Guards durchgeführt werden.

---

# P0 – Kritische Betriebs- und Updatepunkte

## P0.1 Mutable Konfigurationen und Zustände bei Updates vollständig erhalten

### Problem

Der Installer sichert derzeit nur eine kleine feste Liste von Dateien und löscht anschließend das komplette Verzeichnis `/xreactor`.

Aktuell bekannte Preserve-Liste:

```lua
{
  "config/node_id.txt",
  "config/capacity_cache.lua",
  "config/role.lua",
  "config/optional_features.lua",
  "config/ampel_thresholds.lua"
}
```

Andere Laufzeitdateien unter `/xreactor/config` können dadurch bei einem Auto-Update verloren gehen. Dazu gehören unter anderem mögliche rollenbezogene Konfigurationen, `remote_update.lua`, Alert-Zustände, Layoutdaten oder später ergänzte Konfigurationsdateien.

### Ziel

Alle benutzer- oder laufzeitveränderlichen Dateien müssen ein Update überleben, ohne eine vollständige zweite Installation auf der Festplatte anzulegen.

### Umsetzungshinweise

Bevor `/xreactor` gelöscht wird:

1. Das komplette Verzeichnis `/xreactor/config` rekursiv in eine In-Memory-Tabelle einlesen.
2. Pfad und Inhalt jeder Datei sichern.
3. Nach erfolgreicher Neuinstallation die gespeicherten Dateien wiederherstellen.
4. Neu mitgelieferte Default-Konfigurationen dürfen nicht dauerhaft verhindern, dass bestehende Benutzerwerte erhalten bleiben.
5. Vorhandene Config-Normalizer und Migrationsfunktionen sollen alte Konfigurationen nach dem Restore auf das aktuelle Schema bringen.
6. Falls einzelne Dateien bewusst nicht übernommen werden dürfen, muss dafür eine explizite Denylist mit Kommentar und Test existieren. Nicht mit einer kleinen Allowlist arbeiten, die bei jeder neuen Config-Datei vergessen werden kann.

Die Konfigurationen sind normalerweise klein. Deshalb ist ein In-Memory-Backup des Config-Verzeichnisses mit der Speicherbeschränkung vereinbar und benötigt keine zweite Installation auf der Festplatte.

### Zusätzlich prüfen

Mehrere Rollen laden Einstellungen derzeit teilweise direkt aus ausgelieferten Dateien, zum Beispiel aus Rollenpfaden unter `nodes/.../config.lua`. Langfristig sollen benutzerveränderliche Einstellungen unter `/xreactor/config/<rolle>.lua` liegen, während Dateien unter `nodes/...` nur Defaults enthalten.

Diese Migration muss rückwärtskompatibel sein:

- Existiert eine Benutzer-Config unter `/xreactor/config`, wird sie verwendet.
- Existiert sie nicht, werden die ausgelieferten Defaults verwendet.
- Bei erster Speicherung wird die Benutzer-Config unter `/xreactor/config` angelegt.

### Abnahmekriterien

- Eine benutzerdefinierte `/xreactor/config/rt.lua` bleibt nach Auto-Update unverändert erhalten.
- `remote_update.lua`, `alerts_state.lua`, Layoutdateien und zukünftige unbekannte Config-Dateien bleiben erhalten.
- `node_id.txt`, Rolle, Capacity-Cache und optionale Features bleiben weiterhin erhalten.
- Alte Config-Versionen werden nach dem Restore weiterhin normalisiert beziehungsweise migriert.
- Kein vollständiges zweites `/xreactor`-Verzeichnis wird angelegt.

---

## P0.2 Vollständiges Staging – ausdrücklich nicht umsetzen

### Entscheidung

Ein vollständiges Vorab-Stage-Verzeichnis mit allen neuen Dateien wird **nicht** umgesetzt.

### Grund

Der verfügbare Speicher der CC:Tweaked-Computer reicht nicht zuverlässig für alte und neue Installation gleichzeitig. Der Installer wurde in der Vergangenheit regelmäßig wegen voller Festplatte abgebrochen.

### Verbotene Umsetzung

Nicht erneut einführen:

- `/xreactor_stage` mit vollständiger Installation
- `/xreactor_backup_prev` mit vollständiger Installation
- zwei vollständige Rolleninstallationen gleichzeitig
- einen vollständigen Download aller Dateien vor dem Löschen der alten Installation

Kleine `.xr_tmp`- und `.xr_prev`-Dateien für genau die aktuell geschriebene Datei bleiben erlaubt.

---

## P0.3 Delete-and-Reinstall innerhalb der Speichergrenze robuster machen

### Problem

Beim aktuellen Verfahren wird die alte Installation gelöscht und anschließend Datei für Datei neu aufgebaut. Wenn Netzwerk, GitHub oder Manifestprüfung dauerhaft fehlschlagen, kann `/xreactor` unvollständig bleiben.

### Ziel

Das vorhandene Single-Copy-Verfahren soll bestmöglich abgesichert werden, ohne vollständiges Staging.

### Umsetzungshinweise

Vor dem Löschen:

1. Remote-Manifest vollständig laden und syntaktisch prüfen.
2. Rolle und erwartete Dateiliste bestimmen.
3. Prüfen, dass jede Manifestdatei einen gültigen Pfad und plausible Größenangabe besitzt.
4. Gesamten erwarteten Speicherbedarf berechnen.
5. Freien Speicher nach Löschung von löschbaren Logs und Restdateien abschätzen.
6. Update abbrechen, bevor `/xreactor` gelöscht wird, wenn der erwartete Speicher offensichtlich nicht reicht.
7. Benutzerkonfiguration gemäß P0.1 sichern.
8. Einen kleinen, eigenständigen Recovery-Installer außerhalb von `/xreactor` beibehalten, der nach einem Fehlschlag erneut starten kann.

Während der Installation:

- Große und essentielle Dateien zuerst installieren.
- `start.lua`, Bootstrap, Installer-Kern und Rollen-Entrypoint früh installieren.
- Jede Datei nach Download auf Größe, Hash und Lua-Syntax prüfen.
- Bestehende Retry-Logik beibehalten.
- Bei endgültigem Fehler einen klaren Recovery-Status schreiben und nicht still rebooten.

Nach der Installation:

- Vollständigkeitsprüfung gegen die erwartete Rollen-Dateiliste.
- Erst danach Config-Restore abschließen und den erfolgreichen Stand markieren.
- Nur bei vollständigem Erfolg automatisch rebooten.

### Abnahmekriterien

- Bei zu wenig Speicher wird vor dem Löschen der Installation abgebrochen.
- Bei einem permanent fehlgeschlagenen Download bleibt ein startbarer Recovery-Pfad vorhanden.
- Der Nutzer sieht Dateipfad und konkreten Fehlergrund.
- Kein vollständiges Stage- oder Backup-Verzeichnis wird erzeugt.

---

## P0.4 Kleiner Recovery-Bootstrap statt vollständigem Backup

### Ziel

Wenn eine Neuinstallation nach dem Löschen fehlschlägt, muss der Computer selbstständig erneut installieren können.

### Umsetzungshinweise

Ein kleiner Recovery-Bereich außerhalb von `/xreactor` darf enthalten:

- einen minimalen Installer-Downloader
- die gespeicherte Rolle
- die gespeicherte Config-Sicherung oder deren temporäre In-Memory-/kleine Dateiversion
- letzten Installationsfehler
- Retry-Zähler und Backoff

Dieser Recovery-Bereich darf keine vollständige Kopie der Installation enthalten.

`/startup.lua` soll erkennen:

1. `/xreactor/start.lua` vollständig vorhanden → normal starten.
2. Installation als unvollständig markiert → Recovery-Installer starten.
3. `start.lua` fehlt, aber `.xr_prev` existiert → bestehende Einzeldatei-Recovery verwenden.
4. Nichts vorhanden → klare manuelle Installationsanweisung zeigen.

### Abnahmekriterien

- Simulierter Abbruch nach mehreren installierten Dateien führt nach Reboot in den Recovery-Installer.
- Kein endloser `No such program`-Zustand.
- Kein vollständiges Backup der alten Installation.

---

## P0.5 Update-Integrationstests ergänzen

### Neue Pflichtfälle

1. **Config-Preservation-Test**
   - Mehrere Dateien in `/xreactor/config` anlegen.
   - Update simulieren.
   - Alle Dateien müssen inhaltlich erhalten bleiben.

2. **Unknown-Future-Config-Test**
   - Eine dem Installer unbekannte Datei wie `/xreactor/config/future_feature.lua` anlegen.
   - Sie muss das Update überleben.

3. **Low-Disk-Preflight-Test**
   - Freien Speicher unter den erwarteten Bedarf setzen.
   - Installer muss vor dem Löschen abbrechen.

4. **Interrupted-Reinstall-Test**
   - Einen permanenten Downloadfehler mitten im Installationslauf simulieren.
   - Recovery-Pfad und Fehlermarker müssen bestehen bleiben.

5. **Role-Matrix-Test**
   - Preservation und Vollständigkeit für MASTER, RT, ENERGY, WATER, FUEL, REPROCESSING und LOG prüfen.

---

# P1 – Sicherheit, Protokoll und Build-Konsistenz

## P1.1 Commands nur von autorisierten MASTER-Nodes annehmen

### Problem

Ein Node prüft derzeit Ziel-ID und Protokollversion, aber ein beliebiger Computer auf denselben Modemkanälen kann theoretisch eine Nachricht mit `role = MASTER` und einer gefälschten Sender-ID senden.

### Ziel

Steuerbefehle dürfen nur von ausdrücklich autorisierten MASTER-Nodes angenommen werden.

### Mindestumsetzung

- Konfiguration `trusted_master_ids` oder eine einzelne `trusted_master_id` ergänzen.
- Bei Commands Absender-ID gegen diese Liste prüfen.
- Nicht autorisierte Commands mit `UNAUTHORIZED_SENDER` ablehnen und protokollieren.
- HELLO, STATUS und HEARTBEAT dürfen weiterhin zur Discovery sichtbar sein, dürfen aber keinen privilegierten Zustand setzen.
- `master_seen_ts` darf nur durch Nachrichten eines autorisierten Masters aktualisiert werden.

### Optional

Ein gemeinsames Secret oder eine echte Nachrichtenauthentifizierung kann später ergänzt werden. Eine reine CRC ist keine sichere Authentifizierung und darf nicht als solche bezeichnet werden.

### Abnahmekriterien

- Command vom autorisierten MASTER wird ausgeführt.
- Identischer Command von fremder Sender-ID wird abgelehnt.
- Fremde MASTER-Heartbeat-Nachrichten verhindern nicht den AUTONOM-Fallback.
- Ablehnung erscheint in Diagnose und Applied-ACK.

---

## P1.2 Ungültige oder fehlende Protokollversion strikt ablehnen

### Problem

`normalize_proto()` ersetzt nicht erkennbare Protokollversionen aktuell durch die lokale Standardversion. Dadurch kann eine Nachricht ohne gültiges `proto_ver` als kompatibel erscheinen.

### Ziel

Nur ausdrücklich gültige Protokollformate werden akzeptiert.

### Umsetzung

- `normalize_proto()` soll bei unbekanntem Format `nil, error` liefern.
- Fehlendes `proto_ver` → `PROTO_VERSION_MISSING`.
- Ungültiges Format → `PROTO_VERSION_INVALID`.
- Andere Major-Version → `PROTO_MISMATCH`.
- Unterstützte String-, Number- und Table-Legacyformate dürfen weiterhin bewusst normalisiert werden.

### Abnahmekriterien

- Fehlendes `proto_ver` wird abgelehnt.
- Beliebiger String wird nicht zur aktuellen Version umgeschrieben.
- Gleiche Major-Version mit anderer Minor-Version bleibt gemäß aktueller Kompatibilitätspolitik erlaubt.
- Bestehende gültige Nachrichten bleiben kompatibel.

---

## P1.3 Monolithischen Root-Installer automatisch generieren

### Problem

Es existieren zwei zu pflegende Installer-Codebestände:

- modulare Dateien unter `xreactor/installer/`
- eingebettete Kopien im Root-Skript `installer`

In der Vergangenheit liefen beide Versionen auseinander.

### Ziel

Die modularen Dateien sind die einzige Quellwahrheit. Der Root-Installer wird daraus automatisch erzeugt.

### Umsetzung

- Build-Skript unter `scripts/` erstellen.
- Module in deterministischer Reihenfolge in den Root-Installer einbetten.
- Generierte Datei mit deutlichem Header versehen: nicht manuell bearbeiten.
- CI-Guard: Root-Installer neu generieren und Diff prüfen.
- Änderungen an modularen Installerdateien ohne aktualisierte generierte Datei müssen fehlschlagen.

### Abnahmekriterien

- Erneutes Generieren ohne Quelländerung erzeugt keinen Diff.
- Eine Änderung in `xreactor/installer/init.lua` erscheint nach Generierung im Root-Installer.
- CI erkennt Drift zuverlässig.

---

## P1.4 Manifest und Dateien pro Update aus derselben Quelle laden

### Rahmenbedingung

Die aktuelle Beta-Release-Strategie darf nicht stillschweigend auf eine andere Veröffentlichungsstrategie umgestellt werden.

### Ziel

Innerhalb eines einzelnen Updateversuchs dürfen Manifest und Dateien nicht aus unterschiedlichen Ständen gemischt werden.

### Umsetzungsmöglichkeiten

Bevorzugt:

1. Aktuellen Commit-SHA von `beta` einmal auflösen.
2. Manifest von genau diesem SHA laden.
3. Alle Dateien von genau diesem SHA laden.
4. Schlägt SHA-Auflösung fehl, gesamten Versuch auf den Branch-Fallback umstellen und Manifest sowie alle Dateien gemeinsam von `beta` laden.
5. Nicht pro Datei zwischen SHA und Branch mischen.

Alternativ muss eine ebenso konsistente Lösung dokumentiert und getestet werden.

### Abnahmekriterien

- Ein Updateversuch verwendet genau einen Source-Stand.
- Manifest- und Datei-Hashes passen immer zusammen.
- GitHub-Propagation beziehungsweise Rate-Limit führen zu Retry, nicht zu einem gemischten Installationsstand.

---

# P2 – Funktions- und Wartbarkeitsverbesserungen

## P2.1 RT-Monitor zeigt möglicherweise statisches statt tatsächliches RPM-Ziel

### Betroffene Stelle

In `xreactor/nodes/rt/main.lua` wird im Modell für den lokalen Monitor derzeit sinngemäß Folgendes verwendet:

```lua
get_target_rpm = function()
  return reactor_control.get_target_rpm and
    ctx.CONFIG.TARGET_RPM or CONFIG.TARGET_RPM
end
```

### Problem

Dieser Ausdruck ruft keine Funktion auf. Er prüft nur, ob `reactor_control.get_target_rpm` existiert. Wenn die Funktion existiert, wird trotzdem nur der feste Wert `ctx.CONFIG.TARGET_RPM` zurückgegeben.

Außerdem gehört die aktuelle RPM-Zielermittlung nach der übrigen Architektur zum Modul `turbine_control`, nicht zu `reactor_control`.

### Wahrscheinlich richtige Umsetzung

```lua
get_target_rpm = function()
  return turbine_control.get_target_rpm(ctx)
end
```

Vor der Änderung prüfen, ob `turbine_control.get_target_rpm(ctx)` in allen Zuständen einen gültigen Zahlenwert liefert. Bei Fehler oder `nil` darf als UI-Fallback weiterhin `CONFIG.TARGET_RPM` verwendet werden.

Robuste Variante:

```lua
get_target_rpm = function()
  local ok, value = pcall(turbine_control.get_target_rpm, ctx)
  if ok and type(value) == "number" then
    return value
  end
  return CONFIG.TARGET_RPM
end
```

### Erwartete Auswirkung

Die eigentliche Turbinenregelung ist durch die aktuelle Stelle wahrscheinlich nicht betroffen. Es handelt sich voraussichtlich um einen Anzeige- beziehungsweise Modellfehler des lokalen RT-Monitors.

### Abnahmekriterien

- Bei Standardkonfiguration zeigt die UI weiterhin den normalen Zielwert.
- Wird das effektive RPM-Ziel zur Laufzeit verändert, zeigt der Monitor den neuen Wert.
- Ein Fehler beim Lesen des dynamischen Wertes darf die UI nicht zum Absturz bringen.
- Regressionstest prüft, dass die Getter-Funktion tatsächlich aufgerufen wird und nicht nur ihre Existenz geprüft wird.

---

## P2.2 Multi-FUEL- und Multi-WATER-Unterstützung im MASTER-Config-Editor

### Problem

Der MASTER sendet Änderungen an Fuel-Reserve und Water-Target derzeit nur an den ersten gefundenen Node der jeweiligen Rolle.

### Ziel

Bei mehreren Nodes muss das Verhalten eindeutig sein.

### Umsetzung

Eine der folgenden Varianten implementieren und in der UI klar anzeigen:

- konkreten Ziel-Node auswählen
- Änderung an alle Nodes derselben Rolle senden
- beide Modi anbieten: einzelner Node oder alle

Die Auswahl darf nicht von der zufälligen Iterationsreihenfolge einer Lua-Tabelle abhängen.

### Abnahmekriterien

- Bei einem Node bleibt das Verhalten einfach.
- Bei mehreren Nodes ist eindeutig sichtbar, welcher Node geändert wird.
- Broadcast liefert Ergebnis pro Node.

---

## P2.3 Remote-Update-Erfolg anhand Applied-ACKs auswerten

### Problem

Ein gesendeter Update-Command bedeutet noch nicht, dass der Ziel-Node den Command angewendet oder das Update erfolgreich gestartet hat.

### Ziel

MASTER soll zwischen folgenden Zuständen unterscheiden:

- Command gesendet
- zugestellt
- angewendet beziehungsweise Update angenommen
- Timeout
- vom Node abgelehnt

### Umsetzung

- Vorhandene Delivered-/Applied-ACK-Infrastruktur verwenden.
- UI und Log dürfen erst nach Applied-ACK „angenommen“ melden.
- Reboot beziehungsweise vollständiger Updateabschluss kann wegen Verbindungsabbruch separat als „Node rebootet / wartet auf Rückkehr“ dargestellt werden.
- Nach Update Rückkehr des Nodes mit neuer Manifest-/Release-Version prüfen.

### Abnahmekriterien

- Timeout wird nicht als Erfolg angezeigt.
- Ablehnung enthält Reason-Code.
- Rückkehr mit neuer Version wird als abgeschlossen markiert.

---

## P2.4 Dokumentation an den tatsächlichen Installer anpassen

### Problem

Einige Dokumente beschreiben noch vollständiges Stage-/Backup-Verhalten, während der reale Installer aus Speichergründen Delete-and-Reinstall verwendet.

### Ziel

README, Testplan, Migrationsdokumentation und Installer-Kommentare müssen dasselbe Verfahren beschreiben.

### Festzuhaltende Entscheidung

- Kein vollständiges Staging.
- Kein vollständiges Backup.
- Config-Preservation in kleinem Umfang.
- Einzeldatei-Atomic-Write mit `.xr_tmp`/`.xr_prev`.
- kleiner Recovery-Bootstrap.
- Preflight und vollständige Nachprüfung.

### Abnahmekriterien

- Keine aktive Dokumentation behauptet, dass zwei vollständige Installationen parallel gehalten werden.
- Speicherbegründung und Recovery-Strategie sind dokumentiert.
- TESTPLAN enthält die Tests aus P0.5.

---

# Empfohlene Bearbeitungsreihenfolge

1. P0.1 Config-Preservation
2. P0.5 Preservation- und Low-Disk-Tests
3. P0.3 Preflight und Installationsvollständigkeit
4. P0.4 kleiner Recovery-Bootstrap
5. P2.1 dynamisches RPM-Ziel in der RT-UI
6. P1.2 strikte Protokollvalidierung
7. P1.1 MASTER-Allowlist
8. P1.3 generierter Root-Installer
9. P1.4 konsistente Updatequelle
10. P2.3 Update-ACK-Auswertung
11. P2.2 Multi-Node-Config-Editor
12. P2.4 Dokumentation bereinigen

# Allgemeine Definition of Done

Für jeden umgesetzten Punkt gilt:

- vorhandene Tests bleiben grün
- neue Regressionstests werden ergänzt
- Lua-Parse-Guards bleiben grün
- Manifestgröße und CRC32 werden aktualisiert
- `release.lua` und Manifest-Version werden korrekt erhöht
- keine neuen vollständigen Stage- oder Backup-Verzeichnisse
- Fehlerpfade werden sichtbar geloggt
- bestehende Configs bleiben rückwärtskompatibel
