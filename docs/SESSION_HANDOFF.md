# Session Handoff — XReactor Controller V3

> Letzte Aktualisierung: **beta-v318** (2026-07-01)
> Branch: `beta` — Repo: `ItIsYe/ExtreamReactor-Controller-V3`
> Dieses Dokument fasst den aktuellen Stand zusammen und dient als Einstiegspunkt für neue Chat-Sessions.

---

## Aktueller Stand

- **Manifest-Version:** v318
- **Dateien:** 139 manifestierte Dateien (145 → 139 nach Repo-Hygiene-Cleanup, siehe unten)
- **Working Tree:** letzte bekannte Änderungen committed, `manifest.lua`/`release.lua` konsistent (`size_bytes` vollständig gegen echte Repo-Größen verifiziert)
- **ATM10 / MC 1.21.1 / Extreme Reactors 2 / Mekanism / CC:Tweaked**
- Keine bekannten offenen Blocker. Vollständige, chronologische Fix-Historie in `RUNTIME_STATUS_2026-06-03.md` (Repo-Root).

---

## Was in dieser Entwicklungsphase (2026-06-30 bis 2026-07-01) passiert ist

### Installer/Auto-Updater-Härtung
- `role.lua`-Erhalt bei Reinstall vereinheitlicht auf beide Installer-Codepfade (manueller Install UND Auto-Update-Reinstall) — vorher ging die Rollenzuordnung bei jedem Auto-Update verloren, weil nur der seltener durchlaufene manuelle Pfad geschützt war.
- `resolve_sha()` (Extra-Call gegen `api.github.com`) aus dem Auto-Update-Check-Pfad entfernt — verursachte Hänger auf event-intensiven Nodes wie RT.
- `shell.run()` → `dofile()` an mehreren Stellen (`start.lua`, `auto_update.lua`) — `shell` ist in `parallel`-Coroutinen nicht verfügbar.

### Setpoint-Fluss Master → RT (war zeitweise komplett kaputt)
- Feld-Reihenfolge-Bug in `message_handlers.populate_rt_status()`: `node.capacity_max`/`capacity_ready` wurden aus dem **vorherigen** STATUS-Zyklus abgeleitet statt dem gerade eingetroffenen Payload.
- `runtime_ops_profile.estimate_base_power()`: bevorzugte den aktuell gemessenen (ggf. gedrosselten) Output statt der gelernten Maximalkapazität — `power_target` fror beim PEAK-Profilwechsel auf einem alten, niedrigen Wert ein. **Wichtig für zukünftige Sessions:** die Priorität ist jetzt `learned_capacity_total` zuerst, `measured_total` nur als Fallback — falls das jemals wieder umgekehrt erscheint, ist das ein Regressions-Bug, kein beabsichtigtes Verhalten.
- `assigned_power`/`assigned_percent` wurden in `rt_sync.lua` korrekt berechnet, aber nie auf das persistente Node-Objekt geschrieben (nur lokal, verworfen) — UI zeigte deshalb `Soll 0.0`.

### LOG-Collector empfing nichts
Kanal-Mismatch: Sender (`core/remote_log.lua`) nutzte `6502`, `shared/constants.lua` definiert den LOG-Kanal als `6503`. Beide jetzt auf `6503`.

### UI-Redesign (4 Schritte, auf expliziten Nutzerwunsch nach wiederholten Badge-Überlappungen/fehlenden Werten)
1. Neues zentrales `master/ui/layout.lua` — `layout.badge_row()` kennt die Monitorbreite vorher, degradiert gestuft (volle Labels → Kurzformen → niedrigste Priorität entfernen) statt live zu überlappen.
2. Overview-Seite (`master/ui/overview.lua`) um RT-Fleet-Kurzzusammenfassung erweitert.
3. Model-Konsistenz zwischen `ui_controller.build_models()` und den View-Erwartungen verifiziert.
4. Neuer optionaler 1×3-Ampel-Statusmonitor auf RT-Nodes (`nodes/rt/monitor_ui.lua`), automatisch erkannt, reine Statusfarbe. **Wichtige Lehre aus einem gescheiterten ersten Versuch:** ein früher Ampel-Patch hatte keine ausreichende Fehlerisolierung und legte beim Fehlschlagen die komplette RT-Turbinen-Anzeige lahm. Der finale, funktionierende Stand hat `pcall`-Schutz auf jeder Ebene und schließt den Hauptmonitor per tatsächlich aufgelöstem Namen aus (`M.main_monitor_name`, von `M.init()` gesetzt) — nicht per erfundenem Config-Feld.

### Weitere Fixes
- "Overspeed brake pending"-Log-Spam auf 1×/5s pro Turbine begrenzt (flutete vorher den 1000-Zeilen-Log-Ringpuffer bei anhaltendem Overspeed innerhalb weniger Sekunden).
- Doppelte Turbinen-Zeile im RT-Monitor während Capacity-Learning behoben.
- `sequencer.enqueue()` (Master) lehnt jetzt Nicht-String/Number-`node_id` ab, statt sie über `normalize_node_id()` in einen kaputten, aber gültigen String wie `"table:_0x..."` zu verwandeln.

### Repo-Hygiene (v261 → v318, 2026-07-01)
- 6 lose `installer_*.lua`-Dateien im Root gelöscht (~55KB, seit dem monolithischen Installer-Umbau unreferenziert, wurden auf jedem Node unnötig mitinstalliert).
- Verwaistes Duplikat-Verzeichnis `xreactor/xreactor/nodes/rt/` gelöscht (seit ≥v134 bekannt, nie aufgeräumt).
- 3 veraltete v136-Handoff-Notizen und 9 Tests für den ersetzten Stage-Installer-Mechanismus gelöscht.
- `tools/offline_validate.lua` (läuft bei jedem Push in der CI) hatte einen `required`-Dateien-Check, der die 6 gelöschten Dateien weiterhin voraussetzte — wäre sonst ab dem nächsten Push dauerhaft rot gewesen. Gefunden erst in einer zweiten, gründlicheren Nachprüfungsrunde.
- `docs/PROJECT_DOCUMENTATION.md` war eine parallel gepflegte, unabhängige Kopie der README.md-Architekturdoku und dabei zeitweise vom echten Code abgewichen (dokumentierte die `power_target`-Prioritätsreihenfolge invertiert). Auf einen schlanken Verweis reduziert, Inhalte nach README.md konsolidiert.

---

## Bekannte, weiterhin offene, nicht-kritische Punkte

- **Verwaistes Duplikat-Verzeichnis `xreactor/xreactor/nodes/`** — seit mindestens v134 bekannt (siehe historischer Handoff-Text), nie aufgeräumt, ist reiner Repo-Müll, nicht im Installer/Manifest referenziert. Auf Nutzerwunsch bewusst weiterhin nicht angefasst — beim nächsten größeren Aufräum-Task berücksichtigen.
- `enable_reactors`/`enable_turbines` in `ctx.targets`: werden empfangen und gespeichert, aber nicht mehr ausgewertet (State-Machine übernimmt das seit dem SCADA-Rewrite) — kein Bug, bewusst so.
- Keine automatisierten Tests mehr aktiv im Sinne von pytest-Lua-Simulation (historisch entfernt, da CC:Tweaked-Code nicht vollständig außerhalb der echten Umgebung simulierbar ist). Verifikation läuft über echte Installer-Läufe + Log-Analyse.

---

## Wichtige Konfigurationswerte (aktueller Stand)

| Wert | Default | Beschreibung |
|------|---------|-------------|
| `TARGET_RPM` | 900 | Ziel-RPM für alle Turbinen |
| `RECEIVE_TIMEOUT` | 0.5s | Event-Loop Timeout |
| Capacity-Learning Min-Fraction | 80 % | Mindestanteil Turbinen gleichzeitig am Ziel-RPM für eine gültige Messung — bewusst so, kein Bug (siehe Diskussion in RUNTIME_STATUS) |
| Modem Control | 6500 | Master → Nodes |
| Modem Status | 6501 | Nodes → Master |
| Modem Log | **6503** | alle → LOG (war lange fälschlich als 6502 im Sendercode) |
| Ampel-Monitor Größe | 1×1 breit × 3 hoch | exakte Größe für Auto-Erkennung |
| Auto-Update-Intervall | 120s (erster Check nach 30s) | pro Node, läuft in `parallel.waitForAny` neben normaler Node-Logik |

---

## Repo-Struktur (relevante Pfade, aktualisiert)

```
xreactor/
  nodes/rt/
    main.lua               Boot + Service-Wiring
    reactor_control.lua    Rod-Steuerung
    turbine_control.lua    Turbinen-Regelung (inkl. rate-limitiertem Overspeed-Log)
    capacity_learning.lua  Eigenständiges Learning
    status_snapshot.lua    Status-Payload
    state_handlers.lua     State-Machine
    monitor_ui.lua         Lokales Display + Ampel-Statusmonitor (neu)
    discovery_runtime.lua  Peripheral-Erkennung
    binding.lua            Binding-Policy
  master/
    rt_sync.lua             Proportionale Zuweisung, persistiert jetzt assigned_power/percent
    runtime_ops_profile.lua Leistungsschätzung, learned_capacity_total priorisiert
    message_handlers.lua   node.rt wird gemerged statt ersetzt
    ui_controller.lua      build_models(), inkl. alerts/alarms/rt_fleet_summary Models
    ui/
      layout.lua            NEU — zentrales Badge-Layout-System
      overview.lua          erweitert um RT-Fleet-Summary
      multiview.lua         nutzt layout.badge_row()
      rt_dashboard.lua       defensive safe_text() gegen Tabellenwerte in Anzeigefeldern
  core/
    remote_log.lua          Kanal jetzt 6503
  services/
  installer                 monolithisch, PRESERVE-Liste in beiden Codepfaden identisch
  manifest.lua               v318, 139 Dateien
  release.lua                beta-v318
```

---

## Zugang / Arbeitsweise (unverändert gültig)

- Keine Tokens in Chats speichern oder anfordern.
- Bei Connector-Schreibzugriff langsam und atomar arbeiten: Datei lesen, eine kleine Änderung, Commit prüfen.
- Jede Code-Änderung braucht einen Versions-Bump in `manifest.lua`+`release.lua`, sonst zieht kein Node das Update.
- Jede Größenänderung einer manifestierten Datei braucht ein Nachziehen von `size_bytes` im selben Zug — sonst bricht die Installation mit `size mismatch` ab. Bei mehreren aufeinanderfolgenden Patches an derselben Datei diesen Schritt nicht vergessen (war mehrfach Ursache für vermeidbare Fehlschläge in dieser Session).
