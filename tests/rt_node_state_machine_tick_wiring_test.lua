-- tests/rt_node_state_machine_tick_wiring_test.lua
--
-- Regression test (2026-09-18, unabhaengig verifizierter externer
-- Codeanalyse-Befund): node_state_machine:tick() wurde im gesamten
-- RT-Hauptpfad nirgends aufgerufen (verifiziert per grep + git log -S
-- ueber die komplette Historie -- kein Regression, sondern ein seit
-- Bestehen der Datei vorhandener architektonischer Zustand).
-- control_tick() rief reactor_control.updateReactorControl()/turbine_
-- control.updateControl() bisher direkt und unbedingt auf, unabhaengig
-- vom node_state_machine-Zustand -- state_handlers.lua's on_tick-Handler
-- (Watchdog, Startup-Queue, monitor_master()/Kapazitaetslern-Kickstart,
-- EMERGENCY-Semantik) waren dadurch komplett totes Delegations-Ziel.
--
-- nodes/rt/main.lua hat schwere Boot-Zeit-Seiteneffekte und kann nicht
-- per require() instanziiert werden (siehe rt_control_tick_wires_update_
-- module_states_test.lua fuer dieselbe Begruendung) -- dieser Test prueft
-- deshalb strukturell per Quelltext-Suche an control_tick(), dass
-- node_state_machine:tick() tatsaechlich aufgerufen wird, nil-sicher
-- (falls control_tick() vor configure_state_machine() jemals lief) und
-- NACH process_startup() (damit ein frisch gestarteter Modul-Zustand aus
-- demselben Tick sichtbar ist, bevor die State-Machine reagiert).

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

local startup_pos = body:find('module_lifecycle.process_startup(make_lifecycle_ctx())', 1, true)
assert(startup_pos, 'control_tick() must call module_lifecycle.process_startup(make_lifecycle_ctx())')

local guard_pos = body:find('if node_state_machine then', 1, true)
assert(guard_pos, 'control_tick() must guard node_state_machine:tick() against a nil machine (e.g. before boot completes)')

-- Search from the guard onward -- explanatory comments above the guard
-- also mention "node_state_machine:tick()" in prose, which would otherwise
-- match first and falsely fail the ordering check below.
local tick_pos = body:find('node_state_machine:tick()', guard_pos, true)
assert(tick_pos, 'control_tick() must call node_state_machine:tick()')

assert(startup_pos < guard_pos and guard_pos < tick_pos,
  'node_state_machine:tick() must run after process_startup(), inside its nil-guard')

print('rt_node_state_machine_tick_wiring_test.lua: ok')
