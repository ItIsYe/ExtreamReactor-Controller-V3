# Node Start Blockers — 2026-06-25

Dieses Dokument ist eine Übergabe an die nächste KI / den nächsten Bearbeiter.

Stand: `beta` nach LOG collector rewrite und Release/Manifest `v156`.

Wichtig:

- Kein Ingame-Test wurde für diese Analyse gemacht.
- Nichts wurde ingame installiert.
- `xreactor/manifest.lua` ist absichtlich auf `hash_algo = "none"` gesetzt. Das ist **kein Fehler** und soll für diese Fixrunde nicht zurückgedreht werden.
- Dieses Dokument beschreibt die noch offenen Code-Blocker. Es ist keine Aussage, dass die Fixes bereits umgesetzt wurden.

## Kurzfazit

Vor einem späteren Ingame-Test sollten mindestens diese Punkte gefixt werden:

1. `xreactor/nodes/rt/main.lua` — Syntax-/Parse-Blocker in `update_monitor()`.
2. `xreactor/nodes/fuel/main.lua` — fehlender `redstone_router_lib` require und Lua-Scope-Fehler.
3. `xreactor/nodes/water/main.lua` — Lua-Scope-Fehler.
4. `xreactor/nodes/reprocessor/main.lua` — Lua-Scope-Fehler bei `process_state` und `get_feed_router()`.
5. `xreactor/nodes/energy/main.lua` — `record_error` absichern.
6. Danach statische Lua-Parse-/Require-Prüfung über alle betroffenen Rollen.

---

## 1. RT node: Parse-/Syntax-Blocker

Datei:

```text
xreactor/nodes/rt/main.lua
```

Bereich:

```lua
last_status_snapshot = monitor_ui.update(mon, {
  ...
  build_health_payload = function() return build_status_payload() end
  read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
  read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
  ...
  get_device_caps = function(k, n) return turbine_control.get_device_caps(ctx, k, n) end,
  get_available_steam = function() return reactor_control.get_available_steam(ctx) end,
  ...
})
```

Problem:

- Nach `build_health_payload = function() ... end` fehlt ein Komma.
- Prüfen, ob nach weiteren Funktionsfeldern ebenfalls Kommas fehlen.
- Dadurch ist `nodes/rt/main.lua` sehr wahrscheinlich nicht parsebar und RT startet nicht.

Minimaler Fix:

```lua
build_health_payload = function() return build_status_payload() end,
read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
reactor_adapter = adapters.reactor,
turbine_adapter = adapters.turbine,
log_prefix = CONFIG.LOG_PREFIX,
get_device_caps = function(k, n) return turbine_control.get_device_caps(ctx, k, n) end,
get_available_steam = function() return reactor_control.get_available_steam(ctx) end,
```

Zusatzproblem in derselben Tabelle:

```lua
manifest_id = "manifest-v128",
release_id  = "beta-v128",
```

Das ist veraltet. Aktuell ist Release/Manifest `v156`.

Empfohlener Fix:

- Nicht hart codieren.
- Entweder aus `xreactor/release.lua` lesen oder die Felder entfernen, falls `monitor_ui` sie nur optional anzeigt.

Weiteres RT-Logikproblem:

```lua
if message.role == constants.roles.MASTER then
  master_seen_ts = os.epoch("utc")
  ...
  if not master_seen_ts then
    log("INFO", "Master connected: " .. tostring(message.role or "?"))
  end
end
```

Problem:

- `master_seen_ts` wird gesetzt und direkt danach geprüft.
- `if not master_seen_ts` wird dadurch nie wahr.

Empfohlener Fix:

```lua
if message.role == constants.roles.MASTER then
  local was_connected = master_seen_ts ~= nil
  master_seen_ts = os.epoch("utc")
  ...
  if not was_connected then
    log("INFO", "Master connected: " .. tostring(message.role or "?"))
  end
end
```

---

## 2. FUEL node: fehlender require und Scope-Fehler

Datei:

```text
xreactor/nodes/fuel/main.lua
```

### 2.1 Fehlender require

Aktuell wird benutzt:

```lua
rs_router_instance = redstone_router_lib.new({
  config    = config,
  log       = function(level, msg) utils.log("FUEL", msg, level) end,
  warn_once = function(key, msg) warn_once(key, msg) end,
})
```

Aber oben fehlt der Require für `redstone_router_lib`.

Empfohlener Fix im require-Block:

```lua
local redstone_router_lib = require("nodes.fuel.redstone_router")
```

Sinnvoll direkt neben:

```lua
local logistics_router = require("nodes.fuel.logistics_router")
local router_ui_lib     = require("nodes.fuel.router_ui")
```

### 2.2 Lua-Scope-Fehler

`build_status_payload()` ruft auf:

```lua
local master_ok = is_master_connected()
```

`is_master_connected()` wird aber erst später als `local function is_master_connected()` deklariert.

In Lua ist eine spätere `local function` nicht automatisch für bereits definierte frühere Funktionen sichtbar. `build_status_payload()` sieht dann wahrscheinlich ein globales `is_master_connected` und crasht zur Laufzeit.

Empfohlener Fix:

Vor `build_status_payload()` einfügen:

```lua
local master_peer_state
local is_master_connected
```

Spätere Funktionsdeklarationen ändern von:

```lua
local function master_peer_state()
  ...
end

local function is_master_connected()
  ...
end
```

zu:

```lua
master_peer_state = function()
  ...
end

is_master_connected = function()
  ...
end
```

---

## 3. WATER node: Scope-Fehler

Datei:

```text
xreactor/nodes/water/main.lua
```

Problem:

`build_status_payload()` ruft auf:

```lua
local master_ok = is_master_connected()
```

`render_monitor()` nutzt indirekt/extern den Master-Peer-State.

Die Funktionen werden später als lokale Funktionen deklariert:

```lua
local function master_peer_state()
  return role_logic.master_peer_state(comms, constants.roles.MASTER)
end

local function is_master_connected()
  return role_logic.is_master_connected({ ... })
end
```

Das ist für frühere Funktionskörper nicht sicher sichtbar.

Empfohlener Fix:

Vor `build_status_payload()` einfügen:

```lua
local master_peer_state
local is_master_connected
```

Spätere Deklarationen ändern zu:

```lua
master_peer_state = function()
  return role_logic.master_peer_state(comms, constants.roles.MASTER)
end

is_master_connected = function()
  return role_logic.is_master_connected({
    comms = comms,
    master_role = constants.roles.MASTER,
    last_seen_ts = master_seen_ts,
    heartbeat_interval = config.heartbeat_interval
  })
end
```

---

## 4. REPROCESSING node: Scope-Fehler

Datei:

```text
xreactor/nodes/reprocessor/main.lua
```

Problem 1:

`build_status_payload()` nutzt:

```lua
entry.process_state = process_state[entry.id]
```

`process_state` wird aber erst später deklariert:

```lua
local process_state = {}
```

Problem 2:

`build_status_payload()` nutzt:

```lua
payload.feed = get_feed_router():get_summary()
```

`get_feed_router()` wird aber erst später als `local function get_feed_router()` deklariert.

Empfohlener Fix:

Vor `build_status_payload()` einfügen:

```lua
local process_state = {}
local get_feed_router
```

Spätere Zeile:

```lua
local process_state = {}
```

entfernen oder ändern zu:

```lua
process_state = process_state or {}
```

Spätere Funktion ändern von:

```lua
local function get_feed_router()
  ...
end
```

zu:

```lua
get_feed_router = function()
  ...
end
```

Achtung:

- `get_router_ui()` ruft ebenfalls `get_feed_router()`/Router-Funktionen indirekt. Nach der Umstellung auf Forward Declaration sollte das stabil bleiben.

---

## 5. ENERGY node: `record_error` absichern

Datei:

```text
xreactor/nodes/energy/main.lua
```

Auffälligkeit:

`record_error` wird an mehrere Runtime-Module übergeben:

```lua
record_error = record_error
```

Sichtbar u.a. bei:

- `matrix_snapshot_runtime.new(...)`
- `discovery_runtime.new(...)`
- `storage_snapshot_runtime.new(...)`

In den sichtbaren oberen Deklarationen wurde keine lokale Definition von `record_error` gefunden.

Risiko:

- Falls die Runtime-Module `nil` tolerieren, ist es nur unsauber.
- Falls sie `record_error(...)` direkt aufrufen, crasht ENERGY zur Laufzeit.

Empfohlener sicherer Fix vor der ersten Nutzung:

```lua
local function record_error(scope, err)
  local message = tostring(scope or "runtime") .. ": " .. tostring(err or "unknown")
  if devices then
    devices.last_error = message
  end
  if utils and type(utils.log) == "function" then
    pcall(utils.log, "ENERGY", message, "WARN")
  end
end
```

Einfügeort:

- Nach `local devices = runtime.devices`, weil dann `devices` verfügbar ist.
- Vor `init()`, weil dort `record_error` an die Runtime-Module übergeben wird.

---

## 6. Danach statisch prüfen

Nach den Fixes sollte zuerst **ohne Ingame-Test** geprüft werden:

```text
1. Lua-Parse über alle xreactor/**/*.lua
2. Require-Ketten prüfen
3. Rollen-Entrypoints prüfen:
   - xreactor/master/main.lua
   - xreactor/nodes/rt/main.lua
   - xreactor/nodes/energy/main.lua
   - xreactor/nodes/water/main.lua
   - xreactor/nodes/fuel/main.lua
   - xreactor/nodes/reprocessor/main.lua
   - xreactor/nodes/log_collector/main.lua
4. Prüfen, dass Manifest/Release v156 weiterhin absichtlich hash_algo = "none" behalten.
5. Erst danach entscheiden, ob später ein Ingame-Test sinnvoll ist.
```

## Nicht ändern in dieser Fixrunde

Nicht zurückdrehen:

```lua
hash_algo = "none"
```

Grund:

- Das ist aktuell bewusst für den beweglichen `beta` Stand gesetzt.
- Manifest-Metadaten sollen später aus einem echten Checkout sauber regeneriert werden.

## Priorität

Empfohlene Reihenfolge:

1. RT Syntax fixen.
2. FUEL require + Scope fixen.
3. WATER Scope fixen.
4. REPROCESSING Scope fixen.
5. ENERGY `record_error` guard einbauen.
6. Statische Checks laufen lassen.

Vor diesen Fixes sollte das Repo weiterhin nicht ingame installiert oder getestet werden.
