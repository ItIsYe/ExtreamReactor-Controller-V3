# Session Handoff — XReactor Controller V3

**Stand: 2026-09-24 | beta | manifest-v735**

## Aktueller Zustand: stabil, alles auf `beta`

Kein offener PR, keine offene Issue. `beta` ist der aktive Entwicklungszweig;
`main` bleibt unangetastet (stabile Releases, nie direkt bearbeiten).

### Platzbedarf auf dem Knoten

Ein CC-Rechner hat voreingestellt 1 MB. Die Rollen brauchen (mit allen
Zusatzfunktionen):

| Rolle | Dateien | Installation |
|---|---|---|
| RT | 76 | 831 kB |
| MASTER | 71 | 708 kB |
| FUEL | 63 | 604 kB |
| ENERGY | 52 | 461 kB |
| REPROCESSING | 49 | 435 kB |
| VALVE | 32 | 295 kB |
| WATER | 44 | 373 kB |
| LOG | 16 | 147 kB |

RT liegt damit bei rund 83 % eines voreingestellten Rechners — plus
`/xreactor_config`, `/xreactor_logs` und `/startup.lua`. **Fuer RT gehoert
`computer_space_limit` hochgesetzt** (`serverconfig/computercraft-server.toml`).

Zwei Dinge dazu sind seit v734/v735 anders:

- Der Installer prueft den Platz, **bevor** er die alte Installation
  loescht (`stage.check_capacity`). Reicht er nicht, bricht er ab und der
  Knoten laeuft unveraendert weiter. Vorher lief er bis zur letzten Datei
  und liess den Rechner halb installiert liegen.
- Die Installermodule und `manifest.lua` werden nicht mehr mitinstalliert
  (95 kB je Knoten). Ein Knoten liest keines davon je von der Platte: der
  Bootstrap `/installer` laedt seine Module bei jedem Lauf frisch von
  GitHub, und die Buildkennung kommt aus `release.lua`. Einzige Ausnahme
  ist `installer/auto_update.lua`, das `start.lua` laedt. Festgehalten in
  `installer_node_footprint_test.lua`.

Weiteres Sparpotenzial gibt es auf Dateiebene **nicht** — jede noch
installierte RT-Datei ist vom Einstieg aus erreichbar. Der naechste grosse
Posten waere der v1-Regelstapel (rund 191 kB: `turbine_control`,
`reactor_control`, `module_lifecycle`, `state_handlers`, `command_handler`,
`core/turbine_regulator`, `core/control_rails` …), der erst entfallen kann,
wenn v2 v1 endgueltig ersetzt.

### RT-Regel-Engine v2 — laufender Umbau

Der RT-Knoten hat seit 2026-09 eine zweite Regel-Engine (`rt2_*.lua`),
aktivierbar **pro Knoten** mit `engine = "v2"` in `/xreactor_config/rt.lua`.
Ohne den Eintrag laeuft alles unveraendert auf v1. Vollstaendige
Beschreibung: [`RT_ENGINE_V2.md`](RT_ENGINE_V2.md).

Stand:

- Ein einziger Zustandsautomat statt zweier paralleler Systeme; der
  Betriebsmodus wird nicht mehr befohlen, sondern ergibt sich aus der
  MASTER-Verbindung.
- Der Reaktor regelt in JEDEM Zustand nur aus seinem eigenen Dampftank.
- Mehrere Reaktoren an einem Knoten werden unterstuetzt: eine
  Turbinenflotte an einem gemeinsamen Dampfnetz, jeder Reaktor regelt
  unabhaengig aus SEINEM Tank. Keine Zuordnung Turbine -> Reaktor noetig.
  Turbinenzahl nicht begrenzt (nachgemessen bis 100).
- Ein Sicherheitsausloeser faehrt nur seinen eigenen Reaktor ein; erst
  wenn keiner mehr regelbar ist, geht der Knoten auf SAFE.
- Einlernen misst den hoechsten tatsaechlich geflossenen Gesamtausstoss
  (80 % der Flotte muessen dabei gleichzeitig im Zielbereich sein) --
  nicht mehr hochgerechnet.
- Jeder Reaktor vermisst seine eigene Anlage einmalig selbst und leitet
  daraus Stellintervall und Schrittweite ab.

**Offen: der Livetest.** Alle Aussagen stammen aus Tests gegen ein
vereinfachtes Anlagenmodell. Ob v2 v1 ersetzt, ist NICHT beschlossen.

## Architektur-Grundlagen (weiterhin gültig)

- Config (`role.lua`, `node_id.txt`, `reactor_names.lua`, `*_routes.lua`,
  Registry-Dateien) liegt unter `/xreactor_config/` — außerhalb des Baums,
  den der Installer bei jeder (Re-)Installation komplett löscht und neu
  aufbaut. Config wird dadurch nie gelöscht.
- FUEL/WATER/REPROCESSING/RT/VALVE laufen seit PR #543/#544 auf einem
  geteilten Event-Loop (`nodes/support/runtime.lua`'s `run_fast_loop()` +
  `run_slow_loop()`, via `parallel.waitForAny()`): sicherheits-/UI-kritische
  Arbeit (Touch, Comms, Aktor-Ticks) im fast-Loop, langsame Peripherie-Arbeit
  (Discovery, ME-Bridge-Reads, Telemetry) im slow-Loop — verhindert, dass
  eine langsame Peripherie-Abfrage die Touch-UI einfriert. MASTER/ENERGY/
  LOG_COLLECTOR nutzen weiterhin das ältere, ungeteilte `run_event_loop()`.
- `xreactor/release.lua`'s `commit_sha` bleibt IMMER `"beta"` (nicht der
  echte Git-SHA) — `scripts/package_release.py --sync` setzt ihn
  versehentlich auf den echten SHA; nach jedem `--sync`-Lauf manuell
  zurück auf `"beta"` prüfen (siehe `tests/release_metadata_consistency_test.lua`).
- `scripts/package_release.py --sync` erzeugt zusätzlich ein untracked
  `dist/xreactor-release.zip` — nach dem Lauf entfernen (`rm -rf dist`).
- Manifest und `release.lua` vor jedem Commit manuell resynchronisieren
  (`python3 scripts/manifest_sync.py --write`) — CI prüft nur (`--check`),
  aktualisiert aber nichts automatisch.

## FUEL-Logistik (Stand PR #547–#550)

- Ein gemeinsamer `export_chest` für alle Reaktoren; welcher Reaktor
  tatsächlich beliefert wird, entscheidet ausschließlich, welcher
  VALVE-Pfad geöffnet ist (`redstone_router.lua`'s `begin_transaction()`,
  blockiert immer erst alle anderen Pfade). Die Export-Kiste selbst
  braucht kein eigenes Ventil.
- `resupply_cooldown_s` (Default 30s) verhindert, dass FUEL bei jedem
  ~5s-Zyklus erneut nachlegt, solange der Reaktor eine vorige Lieferung
  noch nicht verbraucht/gemeldet hat (Feldbericht: Fuel staute sich sonst
  vor dem Reaktor).
- `logistics.enabled` ist ein bewusster Sicherheits-Default (`false`),
  nie automatisch gesetzt — Touch-Button auf der Router-Seite schaltet ihn um.
- **Hop-Timing** (PR #550, optional): VALVE-Nodes mit lokal verkabelter
  Kreuzungskiste (`config.hop_chest`, `nil` = deaktiviert) melden passiv
  deren Inhalt über den bestehenden Funkkanal. `nodes/fuel/hop_timing.lua`
  lernt daraus reale Transitzeiten pro Streckenabschnitt und macht
  `valve_open_ms` distanzabhängig statt eines festen globalen Werts —
  ohne gelernte Daten bleibt der Timeout exakt der konfigurierte Default,
  unabhängig von der Pfadlänge. Ohne konfigurierte `hop_chest` ändert sich
  am Verhalten nichts.

## VALVE-Node (Stand PR #551)

Optionale lokale 51×19-Terminal-UI am Ventil-Computer selbst
(`nodes/valve/local_ui.lua`): zeigt Status, Master-Verbindung, Pairing,
Hop-Reporter-Status. Genau eine Aktion — SAFE BLOCKIEREN (erzwingt
`apply_valve(true, true)`) — kein lokales Öffnen möglich, das bleibt
exklusiv dem FUEL/VALVE-Netzwerkkommando vorbehalten.

## FUEL-UI (Stand PR #548)

Fest auf 82×40 (8×6 Advanced Monitor, TextScale 1.0) umgestellt, keine
responsive/Legacy-Variante mehr — bei falscher Monitorgröße erscheint ein
Fehlerbildschirm statt eines UI-Fallbacks.

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
- PRs #503-#513 (August 2026) wurden ohne ausreichende Verifikation gemergt,
  viele hatten Abhängigkeiten auf nicht-existente Funktionen
- Fix: Jeden PR einzeln verifizieren (Syntax → Manifest-Resync → volle
  Testsuite → alle `tests/*_test.py`) bevor gemergt wird — seitdem
  Standardablauf für jeden PR in diesem Repo

## Wichtige Regeln

- **NIEMALS** Dateien manuell per curl/Server-Konsole anlegen — immer über den Installer
- Manuell angelegte Dateien → root-Ownership → Berechtigungsprobleme
- Installer-Update: `wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer`
- Vor dem Mergen von Agent-generierten PRs: einzeln verifizieren (siehe oben)

## Backlog — mögliches zukünftiges Feature (nicht priorisiert)

- **Unabhängiger "Wächter"-Mechanismus für RT-Node-Ausfall:** Stürzt
  ausgerechnet der RT-Computer selbst ab (Server läuft normal weiter), läuft
  der Reaktor bis zum automatischen Reboot unbeaufsichtigt auf dem letzten
  Stand weiter. Bewusst zurückgestellt: Risiko eingeschätzt als unkritisch.
  Falls gewünscht: ein zweiter, unabhängiger Node könnte bei
  Kommunikationsausfall eines RT-Nodes proaktiv eingreifen (analog zu
  VALVE's `tick_failsafe`).
- **Positionsabhängige Stau-Diagnose:** mit den HOP_SCAN-Daten aus PR #550
  ließe sich künftig auch erkennen, WO genau eine Lieferung hängt (nicht
  nur, dass der Timeout überschritten wurde) — siehe Diskussion vom
  2026-09-07, noch nicht umgesetzt.

## Doku-Index
- `docs/README.md` — vollständiger Dokumentationsindex
- `docs/CI_MAINTENANCE.md` — CI-Bugs und Fixes
- `docs/SESSION_HANDOFF.md` — dieser Handoff
- `docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md` — historischer
  Gesamt-Audit, wird von ~30 Testdateien referenziert
