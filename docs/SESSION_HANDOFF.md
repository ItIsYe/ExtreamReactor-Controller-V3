# Session Handoff — XReactor Controller V3

**Stand: 2026-09-01 | beta-v598**

---

## Aktueller Zustand: stabil

Der Vorfall aus 2026-08-11 (Agent-Audit-PRs #503–#513, Instabilität durch
`ui_router.lua`-Touch-Handling, Node-Erkennung, Installer-Zweitdurchlauf) ist
abgeschlossen. Diese PRs sind nicht mehr relevant — der Branch `beckup-vor-audit`
wird nicht mehr als Rollback-Ziel benötigt.

**PR #521** (Branch `claude/code-review-bugs-gaps-ug5tff`) bündelt zwei
vollständig abgeschlossene Review-Durchgänge über den gesamten Code:

1. **Bug-Audit** (Commit `079902fa`, 10 Findings, alle behoben, getestet, verifiziert)
   - u.a. pcall-Mehrfachrückgabe-Bugs (`optional/pocket_query_handler.lua`,
     `core/startup_report.lua`), Ratio/Prozent-Verwechslung in
     `nodes/energy/ui_pages.lua`, Enum-Konflation zwischen
     `shared/constants.status_levels` und `core/health.lua` in mehreren
     Master-Dateien, RT-Capacity-Lock-Fix in `nodes/rt/command_handler.lua`.
2. **Performance-Audit** (Commit `4f9121ff`, 16 Findings, alle behoben, getestet, verifiziert)
   - u.a. Remote-Log-Batching (`core/utils.lua` + `nodes/log_collector/main.lua`),
     redundante Peripherie-Abfragen pro Tick (RT-Reaktor/Turbinen-Cache),
     `deep_equal()` statt `textutils.serialize()`-Vergleich in
     `services/ui_service.lua`, generischer Discovery-Stability-Cache
     (`core/discovery_stability.lua`) für WATER/FUEL/REPROCESSING, analog zum
     bestehenden RT-Muster.

3. **Installer/Auto-Update-Härtung** (Commit `d55711c6`): behebt in der Praxis
   beobachtete Timeouts, wenn GitHub `raw.githubusercontent.com`-Anfragen der
   Server-IP wegen zu vieler Anfragen blockiert/rate-limitet hat. Ursache:
   alle Nodes prüften exakt im selben 120s-Takt, jede einzelne Prüfung hat den
   CDN-Cache erzwungen umgangen (nicht nur bei Retries), und ein Fehlschlag
   wurde im selben Takt für immer wiederholt. Fix in
   `installer/auto_update.lua`: Cache-Bust nur noch bei Retries, ein
   node-spezifischer Jitter (aus `os.getComputerID()`) verteilt die Checks
   zeitlich, und wiederholte Fehlschläge verdoppeln die Wartezeit (Cap 30min)
   statt im selben Takt weiterzuhämmern.

Beide Audit-Durchgänge wurden nach demselben Ablauf verifiziert: Syntax-Check
(`luac5.2`/`5.3 -p`) → Manifest-Resync (`scripts/manifest_sync.py --write`) →
vollständige Lua-Testsuite (`tools/run_lua_tests.sh lua5.2`) → alle
`tests/*_test.py` einzeln ausgeführt. Zusätzlich wurde die komplette Kette
Installer → Manifest → Rollen-Dispatch → Node-Boot erneut end-to-end
durchgeprüft (inkl. `manifest_transitive_require_coverage_test.lua`).

CI ist grün, PR #521 ist mergefähig und wird per Scheduled-Check-in
beobachtet. **Der Merge selbst ist eine offene, menschliche Entscheidung** —
nicht Teil dieses Handoffs.

## Bewusst zurückgestellt (nicht Bugs, sondern Abwägungen)

- Log-Verbosity wurde NICHT reduziert — auf expliziten Wunsch werden weiterhin
  alle Log-Level gesendet, nur technisch per Batching entschärft (siehe oben).
- `master/ui_controller.lua`s große primäre RT/Energy/Fuel-Modell-Schleife
  wurde bewusst nicht weiter aufgeteilt (Risiko > Nutzen, siehe Kommentar in
  der Datei).
- Ein paar kosmetische/vernachlässigbare Performance-Findings (LOW priority)
  wurden bewusst nicht angefasst.

## Node-Übersicht

Es liegt aktuell keine Live-Telemetrie aus einem laufenden Minecraft-Server
vor, die diesen Handoff verifizieren könnte. Ein Node-Status-Tabelle wird
daher hier nicht geführt, um keine veralteten oder erfundenen Werte zu
hinterlassen — die Rollen-Übersicht steht im Root-`README.md`.

## Wichtige Regeln

- **NIEMALS** Dateien manuell per curl/Server-Konsole anlegen — immer über den Installer
- Manuell angelegte Dateien → root-Ownership → Berechtigungsprobleme
- Installer-Update: `wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer`
- `xreactor/release.lua`'s `commit_sha` bleibt IMMER `"beta"` (nicht der echte Git-SHA) —
  `scripts/package_release.py --sync` setzt ihn versehentlich auf den echten SHA;
  nach jedem `--sync`-Lauf manuell zurück auf `"beta"` prüfen (siehe
  `tests/release_metadata_consistency_test.lua`)
- `scripts/package_release.py --sync` erzeugt zusätzlich ein untracked
  `dist/xreactor-release.zip` — nach dem Lauf entfernen (`rm -rf dist`)

## ⛔ Nicht nochmal einbauen — gescheiterte Ansätze

### http.get mit Options-Tabelle
- `http.get(url, nil, { timeout = 15 })` → "bad argument #3 (boolean expected, got table)"
- CC:Tweaked unterstützt keine Options-Tabelle als dritten Parameter

### atomic_write mit tmp + fs.move (journal.lua)
- `fs.move` in CC:Tweaked nach Delete/Create nicht zuverlässig → CORRUPT
- Fix: Direkt in Zieldatei schreiben

### GitHub API für SHA-Auflösung
- Rate-Limit 60/h ohne Token → schlägt bei mehreren Computern fehl
- Fix: Direkt `"beta"` als Ref verwenden

### navigate_and_redraw in ui_router
- Funktion existierte nicht → handle_input brach silent ab → kein Seitenwechsel
- Fix: Direkt `self:prev()` / `self:next()` aufrufen mit nav_debounced

### footer/list_controls auf nil setzen bei Transition
- Führt dazu dass Touch-Zonen nach Transition fehlen
- Fix: Nur bei echtem Monitor-/Seitenwechsel nil setzen, nie vorher

### Agent-Audit-PRs blind mergen
- PRs #503-#513 wurden ohne ausreichende Verifikation gemergt
- Viele PRs haben Abhängigkeiten auf nicht-existente Funktionen eingebaut
- Fix: Jeden PR einzeln auf einem Test-Computer verifizieren bevor gemergt wird

## Doku-Index
- `docs/CI_MAINTENANCE.md` — CI-Bugs und Fixes
- `docs/SESSION_HANDOFF.md` — dieser Handoff
