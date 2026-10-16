package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Zahl der Turbinen ergibt sich IMMER aus dem Scan -- es gibt keine
-- feste Zahl (Betreibervorgabe 2026-10-08: aktuell 50 je RT-Node, das kann
-- aber je Knoten verschieden sein).
--
-- Die RT-Node kennt eine feste Geraeteliste (config.turbines/config.reactors
-- in /xreactor_config/rt.lua): steht dort etwas, wird NUR das gebunden.
-- Geschrieben hat solche Listen bis v813 nur ein Fehler. Die Discovery legt
-- den GEFUNDENEN Stand in config.turbines ab, und die Touch-Skalierung des
-- Schirms schrieb die ganze Config auf die Platte -- beim naechsten Start
-- galt der Scan von damals als feste Liste. Neue Turbinen, oder nach einem
-- Modem-Reconnect umbenannte, wurden still ignoriert.
--
--   1. die Migration auf Config-Schema v9 leert solche Listen einmal
--   2. 50 Turbinen werden gefunden und gemeldet
--   3. die Touch-Skalierung schreibt keine Geraeteliste mehr
--   4. nach einem Neustart mit 52 Turbinen werden alle 52 gebunden

local boot = require('support.cc_node_boot')
local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

-- ══ 1. Migration v9 ═══════════════════════════════════════════════════════
do
  local normalizer = require('nodes.rt.config_normalizer')
  local defaults = require('nodes.rt.config')
  assert_true(defaults.version >= 9, 'die RT-Config muss mindestens auf Schema v9 stehen')

  local warnings = {}
  local frozen = { version = 8, reactors = { 'BigReactors-Reactor_1' },
    turbines = { 'BigReactors-Turbine_1', 'BigReactors-Turbine_2' } }
  local changed = normalizer.migrate_schema_version(frozen, defaults, function(w) warnings[#warnings + 1] = w end)
  assert_true(changed, 'v8 -> v9 muss als Aenderung gelten (sonst wird nicht persistiert)')
  assert_eq(#frozen.turbines, 0, 'v9: die feste Turbinenliste muss geleert sein')
  assert_eq(#frozen.reactors, 0, 'v9: die feste Reaktorliste muss geleert sein')
  local noted = false
  for _, w in ipairs(warnings) do
    if w:find(normalizer.DEVICE_LIST_RESET_NOTE, 1, true) then noted = true end
  end
  assert_true(noted, 'v9: das Leeren muss gemeldet werden')

  -- Nach v9 von Hand gesetzt: bleibt stehen.
  local deliberate = { version = defaults.version, turbines = { 'BigReactors-Turbine_7' }, reactors = {} }
  normalizer.migrate_schema_version(deliberate, defaults, function() end)
  assert_eq(#deliberate.turbines, 1, 'eine nach v9 von Hand gesetzte Liste darf nicht geleert werden')
end

local function status(net)
  local message = net:last_message_from('RT', 'STATUS')
  assert_true(message and message.payload, 'die RT-Node meldet keinen Status')
  return message.payload
end

-- Bootet RT (und MASTER) und liefert die Module der RT-Node mit -- vor dem
-- MASTER-Boot gegriffen, der den Modul-Cache neu anlegt.
local function start(turbines, rt_config)
  boot.reset_module_cache()
  local rt = plant.new_rt({ turbines = turbines, node_id = 'node-101', config = rt_config })
  -- Das Verzeichnis der Config, in der Darstellung der Harness ('<dir>',
  -- siehe cc_node_boot's fs.isDir): utils.write_config() legt es an und
  -- prueft danach fs.exists() -- makeDir() der Harness merkt sich nichts.
  rt:add_file('/xreactor_config', '<dir>')
  plant.boot_all({ { name = 'RT', env = rt, main = 'nodes/rt/main.lua' } })
  local rt_modules = rawget(_G, '__xreactor_loaded')
  boot.reset_module_cache()
  local master = plant.new_master({ node_id = 'master-1' })
  plant.boot_all({ { name = 'MASTER', env = master, main = 'master/main.lua' } })
  local net = bus_lib.new()
  net:attach('RT', rt)
  net:attach('MASTER', master)
  net:run(100)
  return rt, net, rt_modules
end

-- ══ 2. 50 Turbinen, per Scan gefunden ═════════════════════════════════════
local rt, net, rt_modules = start(50)
assert_eq(#(status(net).turbines or {}), 50, '50 Turbinen muessen gefunden und gemeldet werden')

-- ══ 3. Touch-Skalierung schreibt keine Geraeteliste ══════════════════════
do
  local monitor_ui = rt_modules and rt_modules['nodes.rt.monitor_ui']
  assert_true(monitor_ui and type(monitor_ui.on_scale_change) == 'function',
    'die RT-Node muss die Touch-Skalierung verdrahten')
  rt:activate()
  monitor_ui.on_scale_change(0.5)
end
local written = rt:read_file('/xreactor_config/rt.lua')
assert_true(type(written) == 'string', 'die Touch-Skalierung muss die Config schreiben')
-- utils.write_config() schreibt eine serialisierte Tabelle; load_config()
-- liest sie als Lua-Chunk oder als textutils-Format.
local chunk = load(written, '=rt.lua', 't', {}) or load('return ' .. written, '=rt.lua', 't', {})
local persisted = assert(chunk, 'rt.lua ist nicht lesbar: ' .. written)()
assert_eq(persisted.monitor_scale, 1, 'die neue Skala muss gespeichert sein')
assert_eq(#(persisted.turbines or {}), 0,
  'die Touch-Skalierung schreibt den Scan als feste Turbinenliste auf die Platte')
assert_eq(#(persisted.reactors or {}), 0,
  'die Touch-Skalierung schreibt den Scan als feste Reaktorliste auf die Platte')

-- ══ 4. Neustart mit 52 Turbinen ══════════════════════════════════════════
--
-- Dieselbe Platte (dieselbe rt.lua), zwei Turbinen mehr gebaut.
local _, net2 = start(52, written)
assert_eq(#(status(net2).turbines or {}), 52, 'nach dem Neustart muessen alle 52 Turbinen gebunden sein')

print('ok rt_turbine_count_from_scan_test')
