-- tests/rt_control_tick_wires_update_module_states_test.lua
--
-- Pflicht-Test fuer RT-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 13 "KRITISCH OFFEN"). module_lifecycle.update_
-- module_states() existierte bereits (und ist bereits per tests/rt_coolant_
-- low_confirm_delay_test.lua funktional getestet), wurde aber im gesamten
-- Produktionscode nirgends aufgerufen -- die einzige weitere Fundstelle war
-- ein Test. control_tick() rief nur process_startup(), Reactor-Control und
-- Turbine-Control auf. Ohne update_module_states() liefen STABLE->RUNNING-
-- Uebergaenge, laufende Modul-Limitbewertung, der Modulstate LIMITED sowie
-- modulbezogene Temperatur-/Coolant-Sicherheitstransitionen nie ausserhalb
-- eines aktiven Startups.
--
-- nodes/rt/main.lua hat schwere Boot-Zeit-Seiteneffekte und kann nicht per
-- require() instanziiert werden -- dieser Test prueft deshalb strukturell
-- per Quelltext-Suche an control_tick(), dass update_module_states()
-- tatsaechlich aufgerufen wird, UND in der dokumentierten sicherheitsersten
-- Reihenfolge (vor process_startup(), vor Reactor-/Turbine-Control).

local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a')
  f:close()
  return c
end

local source = read('xreactor/nodes/rt/main.lua')

local start_pos = source:find('local function control_tick()', 1, true)
assert(start_pos, 'control_tick() not found in nodes/rt/main.lua')
local end_pos = source:find('\nend\n', start_pos, true)
assert(end_pos, 'end of control_tick() not found')
local body = source:sub(start_pos, end_pos)

local update_pos = body:find('module_lifecycle.update_module_states(make_lifecycle_ctx())', 1, true)
assert(update_pos, 'control_tick() must call module_lifecycle.update_module_states(make_lifecycle_ctx())')

local startup_pos = body:find('module_lifecycle.process_startup(make_lifecycle_ctx())', 1, true)
assert(startup_pos, 'control_tick() must still call module_lifecycle.process_startup(make_lifecycle_ctx())')

local reactor_pos = body:find('reactor_control.updateReactorControl(ctx)', 1, true)
assert(reactor_pos, 'control_tick() must still call reactor_control.updateReactorControl(ctx)')

local turbine_pos = body:find('turbine_control.updateControl(ctx)', 1, true)
assert(turbine_pos, 'control_tick() must still call turbine_control.updateControl(ctx)')

-- Documented safety-first ordering: newly dangerous conditions (TEMP/WATER
-- limits -> ERROR/SAFE/EMERGENCY) must be detected and acted on BEFORE this
-- tick's startup progression and control adjustments run against a
-- possibly-stale state.
assert(update_pos < startup_pos,
  'update_module_states() must run before process_startup() (safety-first ordering)')
assert(startup_pos < reactor_pos,
  'process_startup() must run before reactor_control.updateReactorControl()')
assert(reactor_pos < turbine_pos,
  'reactor_control.updateReactorControl() must run before turbine_control.updateControl()')

print('rt_control_tick_wires_update_module_states_test.lua: ok')
