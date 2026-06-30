# Migration Guide (aktueller Repo-Stand — v225)

## Ziel
Diese Migration beschreibt den **aktuellen Installer- und Repo-Stand** für ExtreamReactor-Controller-V3 auf dem `beta`-Branch, Stand Phase-1-bis-4-Rewrite + Auto-Update-Härtung (2026-06-30).

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

---

## Was beim Update/Reinstall erhalten bleibt
- Rolle (`/xreactor/config/role.lua`) — explizit gesichert und wiederhergestellt vor/nach dem Löschen von `/xreactor`.
- `/startup`, sofern ein nicht-XReactor-Startup absichtlich geschützt ist.

**Nicht mehr automatisch erhalten** (da `/xreactor` komplett gelöscht wird): sonstige Runtime-Configs unter `/xreactor/config/*` außer `role.lua`, z. B. `capacity_cache.lua`. Das ist ein bekannter Trade-off des Delete+Reinstall-Ansatzes gegen Speicherplatzprobleme bei großen Rollen — bei Bedarf vor einem manuellen Reinstall sichern.

---

## Aktueller RT-Hinweis
RT ist **nicht** mehr „unverändert/frozen“. Das Modul wurde im Rahmen der SCADA-Rewrite vollständig in Submodule aufgeteilt (siehe README.md → RT Node). RT-bezogene Änderungen müssen immer gegen aktuellen Bootpfad, Config-Schema und `ctx`-Contracts geprüft werden.

---

## Bekanntes offenes Problem (2026-06-30)
**Setpoint-Übertragung/-Berechnung zwischen MASTER und Nodes funktioniert aktuell nicht zuverlässig.** Root Cause noch nicht identifiziert. RT-/Energy-Power-Control-Verhalten ist bis zur Behebung als nicht vertrauenswürdig zu betrachten.

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
7. Bekannte offene Probleme (siehe oben) sind in README.md und hier konsistent dokumentiert.

---

## Abschlussbewertung dieses Dokuments
Dieses Dokument beschreibt den **Ist-Stand nach dem Phase-1–4-Rewrite und der Auto-Update-Härtung** (v225). Es ersetzt den älteren Stage/Backup/Activate-Ansatz vollständig — dieser existiert im aktuellen Installer-Code nicht mehr.

Offen/nicht abgeschlossen:
- Setpoint-Übertragung MASTER ↔ Nodes (siehe oben).
- Vollständige Migration der historischen Shutdown-Workflow-Guards von text-/tokenbasierten Prüfungen zu rein verhaltensbasierten Semantikprüfungen — dieser Punkt war bereits in der Vorversion dieses Dokuments offen und wurde im Rahmen der aktuellen Arbeit nicht angefasst.
