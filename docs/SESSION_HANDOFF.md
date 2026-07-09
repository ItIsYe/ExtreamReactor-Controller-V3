# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v358** (2026-07-08)
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions.

---

## Aktueller Stand

- **Manifest-Version:** v358
- **Dateien:** 156 manifestierte Dateien — komplett auditiert: 0 Größen-/Hash-Abweichungen, 0 fehlende Dateien, keine `hash="new"`-Platzhalter mehr.
- **Alle 6 im Root-`/installer` eingebetteten Module** (http/manifest/stage/ui/auto_update/init) sind Byte-für-Byte identisch mit ihren Quelldateien.
- **ATM10 / MC 1.21.1 / Extreme Reactors 2 / Mekanism / CC:Tweaked**
- Aktive Flotte (bestätigt): MASTER (53), LOG_COLLECTOR (62), RT (52, 63), ENERGY (54, 56, 57, 58) — 8 Nodes.
- Bekannter offener Punkt: siehe unten (AUX:ALERTS-Redesign).

---

## Was seit v343 (2026-07-07 21:00) passiert ist

### Kritischer Absturz-Bug: gesamte Flotte auf v342/v343 eingefroren
Nutzer stellte fest, dass Master + LOG-Collector nach einem Update-Versuch bei CraftOS-Shell ("No such program") hängen blieben, trotz "stundenlanger Laufzeit". Per komplettem `computercraft`-Weltordner-Dump direkt analysiert (nicht nur Log-Exporte) — entscheidender Fortschritt gegenüber reinen Screenshot-Diagnosen:
- **Root Cause:** `installer/auto_update.lua`s `do_check()` lief ungeschützt in einer parallelen Coroutine neben der Rollen-Hauptschleife (`parallel.waitForAny` in `start.lua`). Ein Fehler dort riss die komplette Hauptschleife mit; `start.lua` warf den Fehler danach absichtlich erneut (`error(...)`) statt sich zu erholen — Totalabsturz bis in die CraftOS-Shell, kein Timeout, keine Selbstheilung.
- **Fix:** `do_check()` jetzt `pcall`-isoliert; `start.lua` versucht bei einem kombinierten Coroutine-Fehler jetzt einen automatischen Reboot statt erneut zu werfen.
- Bestätigt flottenweit: alle 8 aktiven Nodes hatten dieselbe liegengebliebene `xreactor_auto_update_installer.lua`-Temp-Datei (exakt v346-Installer-Größe) und steckten bei v342/v343 fest — der Bug traf offenbar alle gleichzeitig.
- Nutzer hat danach alle 8 Nodes manuell neu installiert.

### `_G.__xreactor_remote_update`-Flag-Leak
Diese globale Variable wurde von `run_update()` gesetzt, aber nie zurückgesetzt — blieb für den Rest der Boot-Session `true`. Ein manueller Installer-Lauf direkt nach einem gescheiterten Auto-Update (ohne Reboot dazwischen) erbte den Flag fälschlich und verweigerte die interaktive Rollenauswahl ("keine interaktive Auswahl im unbeaufsichtigten Modus möglich"). Fix: Flag wird nach Gebrauch sofort zurückgesetzt. Sofort-Workaround für Betroffene: einmal rebooten vor dem manuellen Lauf.

### LOG-Collector: keine Crash-Resilienz im Event-Loop
Nur `handle_log_event()` war per `pcall` abgesichert — `draw()`/`refresh_disks()`/`refresh_modems()` liefen ungeschützt. Ein Fehler dort (z. B. in der stark erweiterten `discover_disks()`) tötete den gesamten Loop, landete auf dem Crash-Screen, der bisher **unbegrenzt** auf einen Tastendruck wartete — ohne physische Anwesenheit blieb der Node für immer hängen. Fix: jeder Event-Zweig einzeln `pcall`-isoliert; Crash-Screen startet nach 30s ohne Tastendruck automatisch neu.

### Lesbare Zeitstempel + Heartbeat-Logging
- `nodes/log_collector/main.lua`: jede gespeicherte Log-Zeile bekommt jetzt `[2026-07-08 18:35:11 | <epoch_ms>]` statt nur roher Millisekunden — Ursache war wiederholte Verwechslung von altem/neuem Log-Export in dieser Session.
- `core/logger.lua`: periodischer `HEARTBEAT | alive`-Eintrag alle 60s (piggybacked auf normale Log-Aufrufe), garantiert einen frischen Zeitstempel in jedem Export.

### AUX-Monitor Navigations-Buttons — jetzt vollständig funktionsfähig
Mehrstufige Debugging-Kette, letztlich durch echte Diagnose-Logs (nicht Vermutungen) gelöst:
1. Farbfix (rohe RGB-Hex statt `colors.xxx`) — Buttons wurden sichtbar.
2. **Eigentlicher Bug:** `monitor_sessions.lua`s `resolve_binding(index, prior)` las den `prior`-Parameter nie — `bind_or_update()` läuft bei JEDEM Render-Tick (~alle 0.5–1s) und setzte den `view_key` einer AUX-Session dadurch bei jedem Tick auf die Default-View zurück. Touch funktionierte technisch korrekt (bestätigt per Log: `direction=1` korrekt berechnet), aber die View sprang binnen einer Render-Runde wieder zurück. Fix: gültiger `prior.view_key` wird jetzt beibehalten.
3. Footer überlappte optisch mit dichtem View-Inhalt (RT/Energy) auf manchen Seiten → `height_clamped_mon()`-Proxy in `multiview.lua`: faelscht nur `getSize()` um 1-2 Zeilen weniger fuer AUX-Sessions, jeder View-Renderer reserviert dadurch automatisch Platz fuer den Footer, ohne dass einzelne View-Module angepasst werden mussten.
4. Doppelte "ZURÜCK/WEITER"-Zeile auf `system_map.lua`/`updates.lua` entfernt (beide riefen zusätzlich die ältere, rein dekorative `mux.footer_nav()` mit identischem Default-Text auf).

### AUX:RESOURCES-Absturz bei fehlenden FUEL/WATER-Nodes
`model.fuel`/`model.water` wurden ungeprüft indiziert — bei 0 FUEL/WATER-Nodes (aktueller Flottenstand) blieben diese Sub-Models `nil`, Seite crashte. Jetzt defensiv auf leere Tabellen defaultet.

### AUX:ALERTS — Redesign, noch nicht final
Auf Nutzerwunsch zweimal überarbeitet (dünne Trennlinie → echte "+--STEUERUNG--+"-Box), aber der Nutzer arbeitet parallel mit einer anderen KI an einem umfassenderen Rebuild dieser Seite weiter (Commit `0ba7989`, "rebuild alerts page in approved mockup dashboard style"). **Wichtig:** dieser fremde Commit kam ohne Manifest-/Versions-Update rein — musste nachträglich synchronisiert werden (v356). Falls die andere KI direkt am Repo weiterarbeitet: nach jeder Content-Änderung IMMER `manifest.lua` (size_bytes+hash) und `release.lua`/`manifest_version` mitziehen, sonst kommt die Änderung nie bei den Nodes an.

### Master-Auto-Update: Manifest-SHA-Pinning-Inkonsistenz
Nutzer meldete reproduzierbaren (nicht nur einmaligen) `size mismatch`-Fehler beim Installer, auch nach mehreren Reinstalls. Root Cause: `http_mod.download_file()` hat für einzelne Dateien einen Fallback (SHA-gepinnte URL zuerst, bei Fehlschlag ungepinnter `beta`-Branch-Pfad = garantiert aktuellster Stand) — der **Manifest-Download hatte diesen Fallback nicht**, an zwei unabhängigen Stellen (`installer/init.lua` UND einer separaten Kopie im Root-Wrapper). Wenn `resolve_sha()` einen nicht ganz aktuellen Commit lieferte, der aber trotzdem gültig auflöste, bekam das Manifest alten Stand, während einzelne Dateien über ihren Fallback bereits neuen Stand hatten — persistenter, reproduzierbarer Widerspruch. Fix: Manifest wird jetzt immer vom ungepinnten Branch-Pfad geladen.

### Vollständiger Installations-System-Audit (auf Nutzerwunsch)
- Alle 156 Manifest-Einträge gegen echte Dateien geprüft: 0 Abweichungen.
- 13 verbliebene `hash="new"`-Platzhalter durch echte CRC32-Werte ersetzt.
- **Wichtiger Fund:** der eingebettete `manifest_src`-Block im Root-Installer war NICHT veraltet, sondern hatte gegenüber der aktuellen Quelldatei MEHR Funktionalität — ein Rewrite-Commit vom 28. Juni (`178d4cb`, lange vor dieser Session) hatte in `installer/manifest.lua` sowohl die **interaktive Auswahl optionaler Features** (Ampel/Speaker-Alarm/Pocket-Query-Installationsabfragen) als auch den **kritischen Schutz gegen endloses Hängen bei unbeaufsichtigten Auto-Updates** (Fix vom 6. Juli) entfernt — beides überlebte nur im nie neu gebauten eingebetteten Block. Der eigene SHA-Pinning-Fix (v357) hatte den eingebetteten Block versehentlich aus der bereits regressierten Quelle neu gebaut und damit beide Funktionen live gelöscht. Aus der eigenen Commit-Diff-Historie rekonstruiert und **in die Quelldateien** zurückgeschrieben (nicht nur re-embedded), damit es beim nächsten Rebuild nicht wieder verschwindet.

### Performance-Audit (auf Nutzerwunsch, bewusst zurückhaltend)
Kompletten Node-Bestand durchgesehen, nur einen konkreten, risikoarmen Fund gemacht: `disk_for_role()` im LOG-Collector rief `fs.getFreeSpace()` bei JEDEM eingehenden Log-Event auf (mehrmals pro Sekunde) — jetzt mit 2s-TTL-Cache. Reaktor-/Turbinensteuerung, RT-Sync und Master-Loop-Timing bewusst nicht angefasst (liefen bereits stabil).

### Sicherheitscheck (auf Nutzeranfrage)
Nutzer sah unklare Meldung auf dem LOG-Terminal, befürchtete Datenexfiltration. Komplettes Repo durchsucht: kein einziges `http.post` im gesamten Code — jeder Netzwerk-Aufruf ist reines `http.get`/`http.request`, ausschließlich gegen `api.github.com`/`raw.githubusercontent.com` für das eigene Repo. Keine Upload-Funktion vorhanden.

---

## Bekannte, weiterhin offene Punkte

- **AUX:ALERTS-Seite:** wird von einer anderen KI parallel weiter umgebaut (Stand v356, Commit `0ba7989`). Bei künftigen Änderungen daran: Manifest/Version-Sync nicht vergessen.
- Keine automatisierten Tests mehr aktiv im Sinne von pytest-Lua-Simulation. Verifikation läuft über echte Installer-Läufe + Log-Analyse (jetzt mit lesbaren Zeitstempeln + Heartbeat deutlich einfacher als zuvor).

---

## Wichtige Konfigurationswerte (aktueller Stand)

| Wert | Default | Beschreibung |
|------|---------|-------------|
| `TARGET_RPM` | 900 | Ziel-RPM für alle Turbinen |
| Modem Control/Status/Log | 6500 / 6501 / 6503 | Master↔Nodes / alle→LOG |
| Ampel-Monitor Größe | 1 breit × 3 hoch (Blöcke) | erkannt über 7×19 Zeichen bei Skala 1 |
| Auto-Update-Intervall | 120s (erster Check nach 30s) | pro Node, jetzt pcall-isoliert |
| `DISKS_PER_ROLE` (LOG-Collector) | 4 | Disks pro Rolle, per Label `XR-<ROLLE>-<SLOT>` |
| Heartbeat-Intervall (Logger) | 60s | `core/logger.lua` |
| Crash-Screen Auto-Reboot | 30s | LOG-Collector, kein unbegrenztes Warten mehr |
| `monitor_scale`/`ui_scale_default` (Master) | `nil` | Auto-Skalierung aktiv |
| AUX-Footer Höhen-Reserve | 2 Zeilen | `height_clamped_mon()` in `multiview.lua` |

---

## Repo-Struktur (relevante Pfade, seit v343 neu/geändert)

```
xreactor/
  start.lua                  Auto-Reboot statt Re-Throw bei kombiniertem Coroutine-Fehler
  installer/
    auto_update.lua          do_check() pcall-isoliert, Flag-Leak-Fix
    init.lua                 optionale Feature-Auswahl + Unattended-Guard wiederhergestellt
    manifest.lua              files_for_role() 3-Parameter mit Feature-Filterung wiederhergestellt,
                               Manifest-Fetch nicht mehr SHA-gepinnt
  nodes/log_collector/
    main.lua                  lesbare Zeitstempel, kompletter Loop pcall-isoliert,
                               Crash-Screen mit Auto-Reboot, free_space()-Caching
  master/
    monitor_sessions.lua      resolve_binding() liest prior.view_key jetzt tatsaechlich
    ui/multiview.lua          height_clamped_mon() Footer-Abstand, Diagnose-Logging
    ui/resources.lua          model.fuel/water defensiv defaultet
    ui/system_map.lua         doppelten Footer entfernt
    ui/updates.lua             doppelten Footer entfernt
    ui/alerts.lua              laufendes Redesign (andere KI beteiligt)
  core/
    logger.lua                 Heartbeat-Logging (60s)
  manifest.lua                 v358, 156 Dateien, 0 Platzhalter mehr
  release.lua                  beta-v358
```

---

## Zugang / Arbeitsweise (unverändert gültig, ergänzt)

- Keine Tokens in Chats speichern oder anfordern.
- Jede Code-Änderung braucht einen Versions-Bump in `manifest.lua`+`release.lua`, sonst zieht kein Node das Update — **das gilt auch für Änderungen, die von anderer Stelle (z. B. einer anderen KI) direkt gepusht werden.**
- Jede Größenänderung einer manifestierten Datei braucht ein Nachziehen von `size_bytes`+`hash` im selben Zug.
- Der monolithische Root-`/installer` embeddet mehrere Module als Lua-Long-Strings — nach jeder Änderung an einem dieser Module muss der Block neu gebaut werden. **Wichtig, neu gelernt:** vor dem Rebuild prüfen, ob die Quelldatei wirklich der aktuellere Stand ist — im Zweifel `diff` gegen den eingebetteten Block ziehen, nicht blind überschreiben. Ein Rebuild kann Funktionalität LÖSCHEN, wenn die Quelldatei selbst hinter dem eingebetteten Stand zurückgefallen ist (wie beim manifest.lua-Vorfall in dieser Session).
- Bei Unsicherheit über CC:Tweaked-spezifisches Verhalten erst offizielle Doku (tweaked.cc) konsultieren/nachrechnen statt zu raten.
- Bei mysteriösen, reproduzierbaren Fehlern (nicht nur einmalig): eher an einer echten Logik-Inkonsistenz im Code suchen als vorschnell auf CDN-Cache/Zufall zu schieben — in dieser Session waren mehrere vermeintliche "Cache-Probleme" tatsächlich handfeste Bugs (SHA-Pinning-Inkonsistenz, Flag-Leak).
