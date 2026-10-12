-- Die RT-Bindung haelt keine Geraete-Handles mehr -- und die Eintragslisten
-- bleiben dabei unversehrt.
--
-- Vorgeschichte 1 (Aliasing): nodes/rt/main.lua baute ctx.peripherals und
-- ctx.devices aus DERSELBEN Tabelle. discovery_runtime.M.cache() schrieb
-- ctx.peripherals.reactors/.turbines als name->wrap-Handle-Tabelle und
-- ueberschrieb damit still ctx.devices.reactors/.turbines (die Eintragsliste,
-- die jeder ipairs()-Leser erwartet -- monitor_ui.lua, M.build_modules()).
--
-- Vorgeschichte 2 (Selbstheilung Stufe 1, v817): eben diese wrap-Handles und
-- der Faehigkeiten-Cache (ctx.capability_cache) wurden je Name einmal
-- angelegt und nie erneuert. Kam ein Geraet nach dem Chunk-Laden zuerst mit
-- verkuerzter Methodenliste zurueck, blieben sie auf diesem Stand. Beide
-- sind entfallen; M.cache() heisst jetzt M.normalize_bindings() und
-- uebernimmt nur noch die geprueften Namen.
--
-- Dieser Test faehrt das ECHTE M.refresh_bindings()/M.normalize_bindings()
-- (anders als rt_discovery_runtime_test.lua, der sie ersetzt) und prueft:
--   * ctx.devices.reactors/.turbines bleiben die Eintragsliste
--   * die Bindung bindet NICHTS ein (kein peripheral.wrap) und legt keinen
--     Handle- oder Faehigkeiten-Cache an
--   * die Namen werden weiter nach Geraeteart geprueft

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local wraps = 0
peripheral = {
  getMethods = function(name) return { "x" } end,
  getType = function(name)
    if name:find("reactor", 1, true) then return "BiggerReactors_Reactor" end
    return "BiggerReactors_Turbine"
  end,
  wrap = function(name) wraps = wraps + 1; return { name = name } end,
}

local discovery_runtime = require('nodes.rt.discovery_runtime')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local reactor_entries = { { id = 'REACTOR-1', name = 'reactor_0', kind = 'reactor', bound = true } }
local turbine_entries = {
  { id = 'TURBINE-1', name = 'turbine_0', kind = 'turbine', bound = true },
  { id = 'TURBINE-2', name = 'turbine_1', kind = 'turbine', bound = true },
  -- Ein als Turbine gebundener Name, der sich als Reaktor meldet: fliegt
  -- bei der Pruefung nach Geraeteart heraus.
  { id = 'TURBINE-X', name = 'reactor_odd', kind = 'turbine', bound = true },
}

local devices = { reactors = {}, turbines = {} }
local warnings = {}
local cache_calls = 0
local ctx = {
  config = { reactors = {}, turbines = {} },
  devices = devices,
  utils = {
    -- Gibt es den Aufruf noch, faellt es hier auf.
    cache_peripherals = function() cache_calls = cache_calls + 1; return {} end,
  },
  binding = {
    detect_kind = function(type_name, _method_set)
      if type_name == "BiggerReactors_Reactor" then return "reactor" end
      return "turbine"
    end,
  },
  log = function(level, msg) if level == 'WARN' then warnings[#warnings + 1] = msg end end,
  registry = {
    get_bound_devices = function(_, kind)
      if kind == 'reactor' then return reactor_entries end
      return turbine_entries
    end,
  },
  build_modules = function() end,
}

discovery_runtime.refresh_bindings(ctx)

-- Eintragslisten unversehrt.
assert_eq(#devices.reactors, 1, 'devices.reactors must still be the entry list')
assert_eq(devices.reactors[1].id, 'REACTOR-1', 'devices.reactors entries must keep their id')
assert_eq(#devices.turbines, 3, 'devices.turbines must still be the entry list')
assert_eq(devices.turbines[2].id, 'TURBINE-2', 'devices.turbines entries must keep their id')
assert_eq(devices.reactors.reactor_0, nil, 'devices.reactors must not become a name-keyed map')

-- Nichts eingebunden, nichts gemerkt.
assert_eq(wraps, 0, 'die Bindung darf keine Peripherie einbinden (peripheral.wrap)')
assert_eq(cache_calls, 0, 'die Bindung darf keinen Handle-Cache anlegen (utils.cache_peripherals)')
assert_eq(ctx.peripherals, nil, 'kein ctx.peripherals mehr')
assert_eq(ctx.capability_cache, nil, 'kein ctx.capability_cache mehr')

-- Die Pruefung nach Geraeteart laeuft weiter.
assert_eq(#ctx.config.reactors, 1, 'ein gebundener Reaktor')
assert_eq(#ctx.config.turbines, 2, 'zwei echte Turbinen -- der falsch gebundene Name fliegt heraus')
assert_eq(#warnings, 1, 'und das wird gemeldet')

print('rt_peripherals_devices_isolation_test.lua: ok')
