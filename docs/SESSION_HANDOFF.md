# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v343** (2026-07-07)
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions.

---

## Aktueller Stand

- **Manifest-Version:** v343
- **Dateien:** 156 manifestierte Dateien
- **Working Tree:** letzte bekannte Änderungen committed und gepusht
- **ATM10 / MC 1.21.1 / Extreme Reactors 2 / Mekanism / CC:Tweaked**
- Ein bekannter, noch nicht abschließend verifizierter Punkt: AUX-Monitor-Navigationsbuttons (siehe unten).

---

## Was in dieser Entwicklungsphase (2026-07-07, v330 → v343) passiert ist

### Auto-Update-Robustheit
- `run_update()` loggte bei Fehlschlag bisher nur "alle Download-Versuche fehlgeschlagen" ohne Grund — jetzt wird der tatsächliche Fehler pro Versuch geloggt (HTTP-Code, Timeout, unerwartetes HTML, fs-Fehler).
- `resolve_sha()` rief `api.github.com` bei **jedem** 120s-Check auf — bei mehreren Nodes hinter einer IP wurde so schnell das unauthentifizierte GitHub-Rate-Limit (60/h) gesprengt. Von 3 Versuchen auf 1 reduziert; beide Downloadpfade haben ohnehin einen SHA-losen Fallback.
- **`reclaim()`** aus `installer/stage.lua` (löscht bei Platzmangel `/xreactor_logs`, räumt Backup-/Stage-Reste) wurde nach `installer/auto_update.lua` portiert — der Auto-Updater nutzte das vorher nie und scheiterte an vollem internem Speicher, ohne sich selbst Platz zu schaffen.
- **Cache-Busting** ergänzt für `run_update()`/`fetch_remote_version()` — `raw.githubusercontent.com` cached 5 Minuten; bei mehreren schnellen Pushes hintereinander konnte ein Node sonst veralteten Code ausliefern, obwohl GitHub selbst schon aktueller war.
- Manifest-Platzhalter `hash="new"` (14 Dateien aus dem UI-Redesign, nie durch echte CRC32-Werte ersetzt) sorgte dafür, dass `is_current()` für diese Dateien **immer** `hash_mismatch` meldete → unnötiger Re-Download bei jedem Zyklus. Für die seitdem angefassten Dateien behoben; der Rest ist noch offen (siehe unten).

### LOG-Collector: Mehrere Disks pro Rolle + echtes Labeling
- User hat ingame 4 Disks pro Rolle verbaut (vorher 1). Zwei Bugs machten das kaputt: (1) `discover_disks()` mappte Disk-Index 1:1 auf `ROLE_ORDER[index]` — falsch bei mehreren Disks/Rolle; (2) `table.sort()` auf rohen Mount-Strings sortierte lexikografisch (`disk10` vor `disk2`).
- Erst gefixt über feste physische Gruppen (`DISKS_PER_ROLE=4`, numerischer Sort) mit Round-Robin-Rotation in `disk_for_role()`.
- Danach auf **echtes Disk-Labeling** umgestellt: `find_drives()` liest/schreibt Labels der Form `XR-<ROLLE>-<SLOT>` direkt über die `drive`-Peripherie (`drive.getDiskLabel()`/`setDiskLabel()`). Eine einmal gelabelte Disk behält ihre Rolle dauerhaft, unabhängig von Steckposition — verifiziert per isoliertem Unit-Test (28 frische Disks korrekt verteilt, Stabilität bei komplettem Umstecken, korrekte Ablehnung bei vollen Rollen).

### Ampel-Monitore — 3 Iterationen bis zur echten Lösung
1. **v327** (vorherige Session): Farbwerte waren rohe 24-Bit-RGB-Hex-Zahlen statt `colors.xxx`-Bitmask-Konstanten — Ampel blieb schwarz.
2. **v337**: Größen-Erkennung (`setTextScale(1)`, exakt `w==1,h==3` verlangt) war rechnerisch nie erfüllbar — Fix auf `setTextScale(5)` geraten, aber **führte zu einer kritischen Regression**: die Sondierung lief bei jedem Render-Tick über ALLE Nicht-Ampel-Monitore, setzte testweise Skala 5 und stellte sie bei Fehlschlag **nie zurück** — jeder andere Monitor (inkl. Master-Hauptmonitor, da `master_ampel.lua` nicht mal den Hauptmonitor ausschloss) blieb dauerhaft bei Skala 5 hängen. Sichtbar als kurzer Grün-Blitz gefolgt von dauerhaft zu großer/abgeschnittener UI.
3. **v339**: Regression gefixt — Original-Skala wird vor jeder Sondierung gesichert und bei Fehlschlag sofort wiederhergestellt, plus Ergebnis-Caching (kein Rescan mehr bei jedem Tick).
4. **v340**: Die eigentliche Größen-Erkennung war weiterhin falsch kalibriert (auch ein zwischenzeitlicher Skala-0.5-Heuristik-Versuch hatte einen Logikfehler — Skala 0.5 erhöht die Auflösung, aber es wurde nach *kleinen* Zahlen gesucht). Endgültig gelöst durch Herleitung aus zwei offiziellen CC:Tweaked-Referenzwerten (1 Block @ Skala 1 = 7×5 Zeichen, 3×3-Cluster @ Skala 1 = 29×19 gesamt) → verifizierte Formel `breite(N)=11N-4`, `höhe(M)=7M-2`. Für den 1×3-Ampel-Stack: **exakt 7×19 bei Skala 1**. Vom User bestätigt funktionierend (Ampel zeigt jetzt Farbe).

### Master-UI: Auto-Skalierung war nie aktiv
- `master/config.lua` hatte `monitor_scale=1.0` UND `ui_scale_default=1.0` fest vorgegeben. `core/monitor_manager.lua`s Auto-Skalierung (Feature aus einer früheren Session) greift laut eigenem Code nur, wenn **keine** feste Skala übergeben wird — durch die beiden immer gesetzten Defaults war die Auto-Skalierung seit ihrer Einführung für **jeden** Master komplett tot. Jeder Monitor, auch kleine 1-Block-AUX-Displays, bekam pauschal Skala 1.0 → Inhalte wurden hart abgeschnitten. Fix: beide Defaults auf `nil`, Auto-Skalierung greift jetzt wie vorgesehen.

### AUX-Monitor Navigations-Buttons
- Buttons ("< ZURÜCK" / "WEITER >") waren unsichtbar: `master/ui/multiview.lua` nutzte an 4 Stellen rohe RGB-Hex-Farben (`0xFFFFFF`/`0x000000`) statt `colors.xxx` — derselbe Fehlertyp wie der ursprüngliche Ampel-Bug, nur in einer anderen, beim v327-Fix nicht mit angefassten Datei. Gefixt über `shared/colors.lua` (Palette-Modul, das `core/ui.lua` bereits korrekt nutzt).
- **Danach berichtet:** Buttons sind jetzt sichtbar, aber laut User "nicht schaltbar" bzw. unklar ob am Touch-Handling oder an allgemeiner Render-Trägheit liegend. Code-Review des Touch-Pfads (`loop.lua` → `services:tick` → `ui_controller.handle_input` → `multiview:handle_input` → Hitbox-Vergleich → `cycle_aux_view`) zeigt keine offensichtlichen Logikfehler. **Diagnose-Logging ergänzt** (`utils.log()`-basiert, landet im echten Log-System) an allen `handle_input`-Ausstiegspunkten — zeigt bei nächstem Touch-Versuch Touch-Koordinaten, `session.locked`-Status, gespeicherte Hitbox-Koordinaten und berechnete Richtung. **Noch nicht verifiziert** — der User konnte bisher nur denselben alten Log-Snapshot (18:35 UTC, vor allen v330+-Fixes) erneut hochladen statt eines frischen Exports nach einem echten Touch-Versuch. Nächster Schritt: frischer Log-Export nach Tap direkt am AUX-Monitor.

### Datei-Schreib-Atomizität — vermutliche Ursache für kaputte Nodes nach Update
- User meldete, dass der LOG-Collector-Node nach einem Update mit `CraftOS 1.9` → `No such program` bootete (Indiz: `/startup.lua` fehlte komplett) und jedes Mal ein manueller Reinstall nötig war.
- Root Cause in `installer/stage.lua`s `M.write()`: die Zieldatei wurde **erst gelöscht**, **dann erst** die neue Version reinbewegt (`fs.delete(path)` gefolgt von `fs.move(tmp, path)`). Dazwischen existierte `path` für einen kurzen Moment überhaupt nicht — ein Absturz/Neustart/Stromausfall genau in diesem Fenster hinterlässt eine fehlende Datei ohne Wiederherstellungsmöglichkeit.
- Fix: alte Datei wird zu `.xr_prev` **umbenannt** statt gelöscht (Zieldatei existiert durchgehend), bei fehlgeschlagenem finalem Move wird das Backup zurückgeholt. Root-Installer (`/installer`, monolithisch, embeddet `stage.lua` als String) neu gebaut.
- Eine parallel geprüfte Theorie (der `reclaim()`-Fix hätte ein Rollback-Backup gelöscht) wurde **verworfen**: `/xreactor_backup_prev`/`/xreactor_stage` werden nirgends im Code tatsächlich mit echten Backup-Inhalten befüllt, nur als Cleanup-Ziele referenziert — kein aktives Sicherheitsnetz, das hätte verloren gehen können.

### Heartbeat-Logging (neu)
- `core/logger.lua` (genutzt von MASTER/RT/ENERGY/WATER/FUEL/REPROCESSOR) schreibt jetzt alle 60s automatisch eine `HEARTBEAT | alive`-Zeile, angehängt an jeden normalen `logger.log()`-Aufruf (kein zusätzlicher Call-Site-Umbau nötig). Garantiert einen halbwegs frischen Zeitstempel in jedem Log-Export — macht hängende/abgestürzte Nodes und versehentlich mehrfach hochgeladene, identische alte Log-Exports sofort erkennbar (in dieser Session tatsächlich zweimal passiert: derselbe Snapshot mit MD5-identischem Inhalt wurde für "frisch" gehalten).

### Sicherheits-Check: keine Upload-/Exfiltrations-Funktion vorhanden
- User hatte eine unklare Meldung auf dem LOG-Terminal gesehen ("ssh vaild" o.ä., nicht rekonstruierbar) und Sorge geäußert, es könnte etwas irgendwohin hochgeladen werden.
- Komplettes Repo durchsucht: **kein einziges `http.post`** irgendwo im Code. Jeder Netzwerk-Aufruf ist ein reines `http.get`/`http.request` (Download), ausschließlich gegen `api.github.com`/`raw.githubusercontent.com` für das eigene Repo `ItIsYe/ExtreamReactor-Controller-V3`. Keine fremden Domains, keine Upload-Funktionalität. Erinnerung: ein früherer Versuch, Logs aktiv zu GitHub zu pushen, wurde vom Sicherheits-Check blockiert, bevor irgendwas den Weg ins Repo fand (siehe Git-Historie — kein einziger Commit dazu) und wurde stattdessen durch das oben beschriebene Disk-Log-System ersetzt.

### Sonstiges
- Kosmetischer Altbug im Manifest bereinigt: der `release.lua`-Eintrag hatte sich seit sehr frühen Versionen bei **jedem** Versions-Bump ein zusätzliches `always=true` angesammelt (~29 Duplikate zum Zeitpunkt des Fixes, harmlos in Lua, aber unnötig wachsend).

---

## Bekannte, weiterhin offene Punkte

- **AUX-Monitor Nav-Buttons: Touch-Funktionalität unverifiziert.** Sichtbar seit v341, Diagnose-Logging seit v342 vorhanden, aber noch kein frischer Log-Export nach einem echten Touch-Versuch erhalten. Nächster Schritt: `AUX touch monitor=...`-Zeile im Master-Log nach einem Tap prüfen.
- **13 weitere Dateien mit `hash="new"`-Platzhalter im Manifest** (aus dem UI-Redesign, v286–v299): `core/mockup_ui.lua`, `core/startup_report.lua`, `master/ui/layout.lua`, `master/ui/maintenance.lua`, `master/ui/config_editor.lua`, `optional/speaker_alarm.lua`, `optional/pocket_query_handler.lua`, `nodes/rt/mockup_pages.lua`, `nodes/water/ui_pages.lua`, `nodes/fuel/ui_pages.lua`, `nodes/reprocessor/ui_pages.lua`. `optional/ampel.lua`/`optional/master_ampel.lua`/`release.lua`/`nodes/log_collector/main.lua` wurden im Zuge dieser Session bereits mit echten Hashes versehen. Der Rest führt zu unnötigen Re-Downloads bei jedem Auto-Update-Zyklus, ist aber funktional unschädlich.
- **Verwaistes Duplikat-Verzeichnis `xreactor/xreactor/nodes/`** — war seit ≥v134 bekannt, ist mittlerweile nicht mehr vorhanden (genauer Cleanup-Commit nicht identifiziert), hier nur als erledigt vermerkt.
- Keine automatisierten Tests mehr aktiv im Sinne von pytest-Lua-Simulation (historisch entfernt). Verifikation läuft über echte Installer-Läufe + Log-Analyse.

---

## Wichtige Konfigurationswerte (aktueller Stand)

| Wert | Default | Beschreibung |
|------|---------|-------------|
| `TARGET_RPM` | 900 | Ziel-RPM für alle Turbinen |
| `RECEIVE_TIMEOUT` | 0.5s | Event-Loop Timeout |
| Modem Control | 6500 | Master → Nodes |
| Modem Status | 6501 | Nodes → Master |
| Modem Log | 6503 | alle → LOG |
| Ampel-Monitor Größe | 1 breit × 3 hoch (Blöcke) | erkannt über 7×19 Zeichen bei Skala 1 (siehe oben) |
| Auto-Update-Intervall | 120s (erster Check nach 30s) | pro Node |
| `DISKS_PER_ROLE` (LOG-Collector) | 4 | Disks pro Rolle, per Label `XR-<ROLLE>-<SLOT>` zugeordnet |
| Heartbeat-Intervall (Logger) | 60s | `core/logger.lua`, piggybacked auf normale Log-Aufrufe |
| `monitor_scale`/`ui_scale_default` (Master) | `nil` | Auto-Skalierung aktiv; explizit setzen um zu fixieren |

---

## Repo-Struktur (relevante Pfade, seit dieser Session neu/geändert)

```
xreactor/
  installer/
    auto_update.lua        reclaim() + Cache-Busting + Detail-Logging
    stage.lua               M.write() jetzt luecken-frei atomar (Backup-Rename statt Delete-First)
  nodes/log_collector/
    main.lua                echtes Disk-Labeling (find_drives, XR-<ROLLE>-<SLOT>), Round-Robin
  optional/
    ampel.lua                7x19 @ Skala 1, Skala-Restore + Caching
    master_ampel.lua         dito, plus Haupt-Monitor-Schutz durch Caching
  master/
    config.lua               monitor_scale/ui_scale_default = nil (Auto-Skalierung aktiv)
    ui/multiview.lua         colors.xxx statt roher Hex-Werte, AUX-Touch-Diagnose-Logging
  core/
    logger.lua                periodisches Heartbeat-Logging (60s)
  manifest.lua                v343, 156 Dateien
  release.lua                 beta-v343
```

---

## Zugang / Arbeitsweise (unverändert gültig)

- Keine Tokens in Chats speichern oder anfordern.
- Jede Code-Änderung braucht einen Versions-Bump in `manifest.lua`+`release.lua`, sonst zieht kein Node das Update.
- Jede Größenänderung einer manifestierten Datei braucht ein Nachziehen von `size_bytes`+`hash` im selben Zug — sonst bricht die Installation mit `size mismatch`/`hash_mismatch` ab.
- Der monolithische Root-`/installer` embeddet mehrere Module (u.a. `installer/auto_update.lua`, `installer/stage.lua`) als Lua-Long-Strings — nach jeder Änderung an einem dieser Module muss der Block im Root-`/installer` neu gebaut werden (Marker `local <name>_src = [==[ ... ]==]`), sonst zieht der Auto-Updater weiterhin den alten Code.
- Bei Unsicherheit über CC:Tweaked-spezifisches Verhalten (Monitor-Zeichenauflösung, Farbkonstanten, Peripherie-APIs) erst offizielle Doku (tweaked.cc) konsultieren/nachrechnen statt zu raten — mehrere Bugs in dieser Session entstanden durch ungeprüfte Annahmen über Skalierungs-/Auflösungswerte.
