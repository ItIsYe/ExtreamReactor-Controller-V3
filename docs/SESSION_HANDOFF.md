# Session Handoff — XReactor Controller V3

**Stand: 2026-08-11 | beta-v545 (INSTABIL)**

---

## ⚠️ KRITISCH — Aktueller Zustand

**beta ist aktuell INSTABIL.** Durch Agent-Audit-PRs (#503-#513) sind mehrere Kernfunktionen kaputt gegangen:

- **ui_router.lua Touch-Verarbeitung kaputt** — Seitenwechsel auf allen Nodes funktioniert nicht
- **Master erkennt Nodes nicht** / Nodes gehen ständig offline
- **Installer zweiter Durchlauf** schlägt fehl (Disk-Space für Config-Backup)

## Stabiler Rollback-Punkt

```
Branch: beckup-vor-audit
SHA:    fd26894cd744f93cf66d333de7e5bd44ec24c2be
Stand:  2026-08-09 20:15 (beta-v512)
```

**Nächste Session:** beta auf `beckup-vor-audit` zurückrollen, dann sauber neu aufbauen.

---

## Was noch funktioniert (vor Agent-PRs)

- Installer: Journal-Verify-Fix ✅, SHA-Rate-Limit-Fix ✅, Config-Backup WARN statt Abbruch ✅
- `network_auth.lua` als Repo-Datei (`xreactor/config/network_auth.lua`) ✅
- FUEL Monitor Skala 0.5 ✅

## Node-Übersicht

| Computer | Rolle | Status |
|---|---|---|
| 53 | MASTER | instabil (Node-Erkennung) |
| 54,56,57,58 | ENERGY | läuft |
| 62 | LOG | läuft |
| 64 | FUEL | UI läuft, kein Seitenwechsel |
| 52+ | RT | kein Seitenwechsel |
| 70,74 | VALVE | gelegentliche Aussetzer |

## Wichtige Regeln

- **NIEMALS** Dateien manuell per curl/Server-Konsole anlegen — immer über den Installer
- Manuell angelegte Dateien → root-Ownership → Berechtigungsprobleme
- Installer-Update: `wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer`
- Branches: `main` (stabil), `beta` (aktuell instabil), `beckup-vor-audit` (stabiler Rollback)

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
- `docs/REPO_SAFETY_AUDIT_CLOSURE_2026-08-10.md` — Safety-Audit August 2026
