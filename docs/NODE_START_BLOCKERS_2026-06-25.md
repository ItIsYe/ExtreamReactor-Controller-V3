# Node Start Blockers — aktueller Stand

Aktuelle statische Nachprüfung: 2026-06-30, `beta` / `beta-v236`.

Wichtig:

- Kein Ingame-Test wurde für diese Prüfung gemacht.
- Nichts wurde ingame installiert.
- Auf Wunsch wurde der RT-Codeblocker **nicht** im Code behoben, sondern nur dokumentiert.
- Diese Datei beschreibt den aktuell sichtbaren Repo-Stand und offene Prüfpunkte.

## Ergebnis

Der frühere `beta-v165`-Stand ist überholt. Das Repo steht aktuell auf `manifest-v236` / `beta-v236`, aber mehrere Doku- und Konsistenzpunkte sind offen.

Der wichtigste technische Blocker bleibt:

```text
xreactor/nodes/rt/main.lua
```

Dort fehlt weiterhin ein Komma in der Tabelle für `monitor_ui.update(...)`. Dieser Punkt wurde bewusst **nicht** behoben, sondern nur dokumentiert.

## Aktuell offen

### 1. RT Parse-/Syntax-Blocker — bewusst nur dokumentiert

Datei:

```text
xreactor/nodes/rt/main.lua
```

Aktueller Bereich:

```lua
last_status_snapshot = monitor_ui.update(mon, {
  ...
  build_health_payload = function() return build_status_payload() end
  read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
  read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
  ...
})
```

Problem:

- Nach `build_health_payload = function() ... end` fehlt ein Komma.
- Minimal korrekt wäre:

```lua
build_health_payload = function() return build_status_payload() end,
read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
```

Einschätzung:

- Das ist sehr wahrscheinlich ein harter Lua-Parsefehler für RT.
- `xreactor/start.lua` enthält aktuell keinen Self-Heal mehr, der diese Stelle vor dem Start repariert.
- Solange dieser Punkt offen ist, sollte RT nicht als sauber startfähig gelten.

Status:

```text
OFFEN — nicht im Code behoben, nur dokumentiert.
```

### 2. RT Build-Werte sind veraltet/hart codiert

Datei:

```text
xreactor/nodes/rt/main.lua
```

Aktuell sichtbar:

```lua
manifest_id = "manifest-v158",
release_id  = "beta-v158",
```

Aktueller Release-/Manifest-Stand:

```text
manifest-v236 / beta-v236
```

Problem:

- Anzeige/Diagnose im RT-Monitor ist dadurch falsch.
- Kein direkter Startblocker, aber verwirrend beim Debuggen.

Empfehlung:

- Nicht hart codieren.
- Dynamisch aus `xreactor/release.lua` oder `shared.build_info` lesen.

Status:

```text
OFFEN — nur dokumentiert.
```

### 3. Manifest/Release `hash_algo` inkonsistent

Dateien:

```text
xreactor/manifest.lua
xreactor/release.lua
```

Aktuell sichtbar:

```lua
-- manifest.lua
manifest_version = 236
manifest_id = "manifest-v236"
hash_algo = "none"
```

```lua
-- release.lua
release_id = "beta-v236"
manifest_id = "manifest-v236"
hash_algo = "crc32"
```

Problem:

- Manifest und Release widersprechen sich.
- Für den beweglichen Beta-Stand war `hash_algo = "none"` vorher bewusst gesetzt.
- Wenn CRC32 genutzt werden soll, müssen alle `size_bytes`/`hash` Werte aus einem echten Checkout sauber regeneriert und geprüft werden.

Status:

```text
OFFEN — nur dokumentiert.
```

### 4. Manifest-Kommentar inkonsistent

Datei:

```text
xreactor/manifest.lua
```

Aktuell sichtbar:

```lua
-- xreactor/manifest.lua -- manifest-v225
return {
  manifest_version = 236,
  manifest_id = "manifest-v236",
```

Problem:

- Kommentar sagt `manifest-v225`.
- Werte sagen `manifest-v236`.

Status:

```text
OFFEN — kein Runtime-Blocker, aber Doku-/Hygieneproblem.
```

### 5. Remote-Update Token-Weitergabe prüfen

Datei:

```text
xreactor/core/remote_update.lua
```

Aktuell sichtbar:

```lua
function M.handle_command(opts)
  ...
  return M.run(log)
end
```

Problem:

- `handle_command(opts)` prüft zuerst `opts`, inklusive möglichem Token.
- Danach ruft es `M.run(log)` ohne `opts` auf.
- `M.run(log_fn, opts)` prüft Arming erneut.
- Wenn ein Token verwendet wird, könnte die zweite Prüfung ohne `opts` an `token mismatch` scheitern.

Empfehlung:

```lua
return M.run(log, opts)
```

Status:

```text
OFFEN — nur dokumentiert.
```

### 6. README / Doku-Versionen waren veraltet

Mehrere Dokumente zeigten noch ältere Versionen:

- `docs/NODE_START_BLOCKERS_2026-06-25.md` vorher `beta-v165`
- `docs/README.md` vorher `manifest-v156` / `beta-v156`
- `docs/PROJECT_DOCUMENTATION.md` vorher `beta-v133`
- Root `README.md` vorher `manifest-v225` / `beta-v225`

Status:

```text
DOKU-WIRD-AKTUALISIERT — diese Datei ist jetzt auf beta-v236 aktualisiert.
```

## Sichtbar verbessert gegenüber den alten Logs

### Master → RT Setpoints

Der aktuelle `xreactor/master/rt_sync.lua` sendet Setpoints sichtbar immer per:

```lua
M.send_rt_setpoints(ctx.comms, node, desired)
```

Das alte Log-Problem `RT setpoints deduped ... ACK_MATCH` ist im aktuellen Code nicht mehr sichtbar.

Status:

```text
SICHTBAR VERBESSERT — später ingame/logbasiert erneut prüfen.
```

### Remote-Update Schutz

`xreactor/core/remote_update.lua` ist sichtbar arming-geschützt:

```text
/xreactor/config/remote_update.lua
return { enabled = true }
```

Optional mit Token:

```lua
return { enabled = true, token = "..." }
```

Status:

```text
SICHTBAR VERBESSERT — Token-Weitergabe siehe offener Punkt 5.
```

### Auto-Update / Startstruktur

`xreactor/start.lua` startet inzwischen zusätzlich einen Auto-Update-Loop, wenn `installer/auto_update.lua` vorhanden ist.

Status:

```text
SICHTBAR NEU — bei späteren Tests besonders Logs zu Auto-Update und Install-Restart prüfen.
```

## Bekannte alte Punkte, die im aktuellen Code nicht mehr im Vordergrund stehen

Diese älteren Blocker wurden in früheren Prüfungen sichtbar behoben oder sind durch Umbauten nicht mehr der Hauptfokus:

- FUEL: `redstone_router_lib` require / Scope-Fixes.
- WATER: `is_master_connected` / `master_peer_state` Scope-Fixes.
- REPROCESSING: `process_state` / `get_feed_router` Scope-Fixes.
- ENERGY: `record_error` Callback ist vorhanden.
- LOG Collector: Header-Overlap war sichtbar gefixt.

Diese Punkte sollten bei einer späteren vollständigen statischen Prüfung trotzdem erneut kontrolliert werden.

## Nächste empfohlene Reihenfolge

1. RT-Kommafehler in `xreactor/nodes/rt/main.lua` beheben.
2. RT Build-Werte dynamisch machen oder auf `v236` aktualisieren.
3. Manifest/Release `hash_algo` vereinheitlichen.
4. Manifest-Kommentar auf `manifest-v236` korrigieren.
5. Remote-Update `M.run(log, opts)` prüfen/patchen, falls Token genutzt werden soll.
6. Danach statische Lua-Parse-/Require-Prüfung über alle Rollen.
7. Erst danach späterer Ingame-Test.

Bis Punkt 1 erledigt ist, gilt RT weiterhin als nicht sauber startbereit.
