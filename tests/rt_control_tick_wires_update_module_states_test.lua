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

-- 2026-09-18: reactor_control.updateReactorControl(ctx)/turbine_control.
-- updateControl(ctx) are no longer called directly from control_tick() --
-- node_state_machine:tick() now delegates to state_handlers.lua's
-- on_tick handlers (running_on_tick()/limited_on_tick()/etc.), which call
-- adjust_reactors()/adjust_turbines() themselves. See rt_state_handler_
-- context_wiring_test.lua (drives that delegation directly) and rt_
-- node_state_machine_tick_wiring_test.lua (structural check that this
-- exact call exists here).
local tick_pos = body:find('node_state_machine:tick()', 1, true)
assert(tick_pos, 'control_tick() must call node_state_machine:tick() to delegate to state_handlers.lua')

-- Documented safety-first ordering: newly dangerous conditions (TEMP/WATER
-- limits -> ERROR/SAFE/EMERGENCY) must be detected and acted on BEFORE this
-- tick's startup progression and control adjustments run against a
-- possibly-stale state.
assert(update_pos < startup_pos,
  'update_module_states() must run before process_startup() (safety-first ordering)')
assert(startup_pos < tick_pos,
  'process_startup() must run before node_state_machine:tick()')

print('rt_control_tick_wires_update_module_states_test.lua: ok')
