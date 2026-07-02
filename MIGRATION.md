# Migration Guide (aktueller Repo-Stand — v262)

## Ziel
Diese Migration beschreibt den **aktuellen Installer- und Repo-Stand** für ExtreamReactor-Controller-V3 auf dem `beta`-Branch, Stand Phase-1-bis-4-Rewrite + Auto-Update-Härtung + UI-Redesign (2026-07-01).

Wichtig:
- Der normale Installer-Lauf ist **beta-only**.
- Der Installer ist **ein einziges monolithisches Skript** (`/installer` im Repo-Root), das die `installer/`-Module als eingebettete Lua-Long-Strings enthält. Es gibt keine separate `installer_main.lua` mehr.
- Der Installer lädt Metadaten (`release.lua`, `manifest.lua`) live vom `beta`-Branch.
- Commit-Pinning ist im normalen `beta`-Installerpfad **nicht erlaubt**.

---

## Aktueller Install-/Update-Flow

### Neuinstallation / Reinstallation (identischer Flow)
1. `installer` lokal starten (`wget .../beta/installer` + ausführen).
2. Rolle wählen (bei Reinstall: bestehende Rolle wird automatisch erkannt und vorgeschlagen).
3. Der Installer lädt `manifest.lua` vom `beta`-Branch und ermittelt über `files_for_role()` die für die gewählte Rolle nötigen Dateien.
4. **Vor dem Löschen** wird `/xreactor/config/role.lua` eingelesen und im Speicher zwischengespeichert.
5. `/xreactor` wird komplett gelöscht (`fs.delete`) und neu angelegt — **kein** separates Stage/Backup-Verzeichnis mehr. Das verhindert verwaiste Altdateien und Speicherplatzprobleme bei großen Rollen (MASTER, RT).
6. `role.lua` wird sofort wiederhergestellt, damit ein Neustart des Installers (z. B. nach Abbruch) die Rolle weiterhin kennt.
7. Die eingebetteten `installer/*.lua`-Module werden nach `/xreactor/installer/` geschrieben.
8. Die erwarteten Node-Dateien werden direkt von GitHub (`raw.githubusercontent.com`) heruntergeladen und in `/xreactor` geschrieben (größte Dateien zuerst).
9. `/xreactor/config/remote_update.lua` wird geschrieben (`enabled=true, auto_update=true, check_interval_s=120`).
10. `/startup` wird geschrieben.
11. `os.reboot()`.

### Auto-Update (kein manueller Trigger nötig)
Jeder Node startet nach dem Boot `parallel.waitForAny(node_thread, auto_update_loop)`. Der Auto-Update-Loop:

1. Wartet 30s nach Boot, danach alle 120s.
2. Liest lokale `manifest_version` aus `/xreactor/release.lua`.
3. Holt `xreactor/release.lua` direkt von `raw.githubusercontent.com/.../beta/...` (kein `api.github.com`-Umweg mehr, siehe unten).
4. Ist die Remote-Version höher, lädt er den aktuellen `/installer` herunter, führt ihn via `dofile()` aus (nicht `shell.run()` — `shell` ist in `parallel`-Coroutinen nicht verfügbar) und rebootet bei Erfolg.
5. Bis zu 3 Versuche mit Backoff, danach 60s Pause vor dem nächsten regulären Zyklus.

---

## Wichtige Strategie-Regeln

### 1. Beta-only bedeutet: kein Commit-Pin
Im normalen Installerlauf gilt:

- `release.lua.commit_sha` darf **kein echter Commit-SHA** sein
- `release.lua.source_ref` muss zu `beta` passen
- `manifest.lua.source_ref` (falls vorhanden) muss zu `beta` passen

### 2. Remote-Metadaten, lokaler Commit
Metadaten und Dateien werden vom `beta`-Branch geladen; das Schreiben nach `/xreactor` passiert lokal auf dem Zielsystem. Es gibt **keine** Stage/Backup/Activate-Trennung mehr (siehe oben) — der alte dreistufige Ansatz mit `/xreactor_stage` und `/xreactor_backup_prev` wurde durch Delete+Reinstall-mit-role.lua-Erhalt ersetzt.

### 3. Manifest ist verbindlich
Alle Dateien im Installerpfad werden über `manifest.lua` (Pfad, `size_bytes`) referenziert. **Jede Versions-Bumps muss `manifest_version` in `manifest.lua` UND `release.lua` erhöhen, sonst erkennt der Auto-Updater die neue Version nicht.**

### 4. CC:Tweaked Parallel-Coroutine-Regeln (siehe auch README.md)
Hart erarbeitete Einschränkungen, die beim Schreiben von Installer-/Auto-Update-Code beachtet werden müssen:
- `shell` nicht verfügbar in `parallel`-Coroutinen → `dofile()` statt `shell.run()`.
- `http.get()` ohne brauchbares Timeout in diesem Kontext → async `http.request` + `http_success`/`http_failure` Events.
- Keine zusätzlichen abhängigen HTTP-Roundtrips im Update-Check-Pfad (z. B. SHA-Auflösung über `api.github.com`) — jeder zusätzliche externe Call ist ein weiterer Punkt, an dem der async Event-Wait auf event-intensiven Nodes (z. B. RT) hängen bleiben kann. Direkt `raw.githubusercontent.com/.../beta/...` fetchen.
- `os.pullEvent()` in parallelen Threads ungefiltert lassen, damit Geschwister-Coroutinen ihre Events weiterhin bekommen.
- `f.write(content)` direkt aufrufen, nicht über `pcall(f.write, f, content)`.

### 5. Log-Transport-Kanal ist 6503, nicht 6502
War lange ein realer Bug: der Sender (`core/remote_log.lua`) nutzte fest `6502`, während `shared/constants.lua` den LOG-Kanal als `6503` definiert (bewusst getrennt von Control/Status 6500/6501). Der LOG-Collector empfing dadurch über einen längeren Zeitraum nichts (`Recv 0`), obwohl alles andere korrekt konfiguriert war. Fixed 2026-06-30 — beide Seiten nutzen jetzt `6503`.

---

## Was beim Update/Reinstall erhalten bleibt
- Rolle (`/xreactor/config/role.lua`) — explizit gesichert und wiederhergestellt vor/nach dem Löschen von `/xreactor`.
- `/startup`, sofern ein nicht-XReactor-Startup absichtlich geschützt ist.

**Nicht mehr automatisch erhalten** (da `/xreactor` komplett gelöscht wird): sonstige Runtime-Configs unter `/xreactor/config/*` außer den explizit in `PRESERVE` gelisteten Dateien.

**In `PRESERVE` gesichert (seit 2026-07-01, v235):** `config/node_id.txt`, `config/capacity_cache.lua`, `config/role.lua` — alle drei überleben Reinstalls und Auto-Updates in beiden Installer-Codepfaden.

---

## Aktueller RT-Hinweis
RT ist **nicht** mehr „unverändert/frozen“. Das Modul wurde im Rahmen der SCADA-Rewrite vollständig in Submodule aufgeteilt (siehe README.md → RT Node). RT-bezogene Änderungen müssen immer gegen aktuellen Bootpfad, Config-Schema und `ctx`-Contracts geprüft werden.

---

## Historisch gelöste Probleme (Kontext für zukünftiges Debugging)

Diese Punkte waren zeitweise offen, sind aber inzwischen gefixt — hier gelistet, damit nicht erneut Zeit in bereits geschlossene Themen investiert wird:

- **Setpoint-Übertragung/-Berechnung MASTER ↔ Nodes** (offen bis 2026-06-30/07-01): zwei getrennte reale Bugs — ein Feld-Reihenfolge-Fehler in `populate_rt_status()` (message_handlers.lua) ließ `node.capacity_max`/`capacity_ready` immer einen Zyklus veraltet erscheinen, und `estimate_base_power()` bevorzugte den aktuell gemessenen (ggf. gedrosselten) Output statt der gelernten Maximalkapazität für das PEAK-Profil. Beide gefixt, siehe RUNTIME_STATUS_2026-06-03.md.
- **LOG-Collector empfängt nichts** (Recv 0): Kanal-Mismatch 6502 vs. 6503, siehe oben.
- **role.lua ging bei jedem Auto-Update verloren**: nur im manuellen Installer-Codepfad geschützt, nicht im (weit häufiger durchlaufenen) Auto-Update-Reinstall-Pfad. Gefixt 2026-07-01, beide Pfade nutzen jetzt dieselbe `PRESERVE`-Liste.

---

## Pfade

### Installer-relevant
- Install root: `/xreactor`
- Installer-Source intern: `/xreactor/installer/*.lua` (aus dem monolithischen Installer geschrieben)
- Auto-Update Arming-Config: `/xreactor/config/remote_update.lua`
- Temporäre Auto-Update-Installerdatei: `/xreactor_auto_update_installer.lua` (wird nach Ausführung gelöscht)

### Runtime-/Logging-Pfade
- Rollen-/Knoten-bezogene Runtime-Dateien unter `/xreactor/config/*`
- LOG-Collector-Logs: dateibasiert auf angeschlossenen Disk-Laufwerken, ein Eintrag pro Node (`<role>.log`)

---

## Verbindliche Prüfliste vor Freigabe

1. `release.lua` und `manifest.lua` haben identische `manifest_version` und passende `manifest_id`/`release_id`.
2. `release.lua.source_ref` / Branch-Bezug passt zu `beta`, kein Commit-Pin.
3. Jede Code-Änderung am Installer/Auto-Updater wurde mit einem Versions-Bump gepusht — sonst zieht kein Node das Update.
4. Neue/role-spezifische Dateien sind korrekt in `manifest.lua` unter `roles.<role>` mit passendem `required_for` eingetragen.
5. Bei Änderungen an `installer/auto_update.lua` oder `start.lua`: gegen die Parallel-Coroutine-Constraints oben prüfen (`shell`, `http.get` Timeout, `os.pullEvent`).
6. RT-Bootpfad wurde auf offensichtliche Folgeblocker mitgeprüft.
7. Neue/geänderte Datei-Größen (`size_bytes`) in `manifest.lua` wurden für JEDE geänderte Datei nachgezogen — ein Mismatch bricht die Installation für jeden Node ab, der diese Datei braucht.

---

## Abschlussbewertung dieses Dokuments
Dieses Dokument beschreibt den **Ist-Stand nach dem Phase-1–4-Rewrite, der Auto-Update-Härtung und dem UI-Redesign** (v262). Es ersetzt den älteren Stage/Backup/Activate-Ansatz vollständig — dieser existiert im aktuellen Installer-Code nicht mehr.

Offen/nicht abgeschlossen:
- Vollständige Migration der historischen Shutdown-Workflow-Guards von text-/tokenbasierten Prüfungen zu rein verhaltensbasierten Semantikprüfungen — dieser Punkt war bereits in einer früheren Version dieses Dokuments offen und wurde bislang nicht angefasst.
