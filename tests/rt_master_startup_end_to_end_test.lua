package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer MASTER-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 3). Vor diesem Fix waren nodes/rt/main.lua's
-- request_startup_if_needed/start_module reine No-Op-Stubs -- der reale
-- RT-Command-Handler-Pfad (command_handler.lua STARTUP_STAGE -> ctx.
-- start_module) wurde daher nie tatsaechlich geprueft. Dieser Test treibt
-- exakt diesen Pfad -- command_handler.new(ctx) mit echten COMMAND-Messages,
-- echtem module_lifecycle.start_module/process_startup, echten Modul-
-- Zustandsuebergaengen -- ohne main.lua's schwere Peripheral-/Service-Boot-
-- Abhaengigkeiten zu benoetigen (Mock-Peripherals, wie im uebrigen rt_
-- module_lifecycle_*-Testset ueblich).

local clock = 1000000
os.epoch = function() return clock end

local constants = require('shared.constants')
local module_lifecycle = require('nodes.rt.module_lifecycle')
local command_handler_lib = require('nodes.rt.command_handler')
local startup_diagnostics = require('nodes.rt.startup_diagnostics')
local health_payload_lib = require('nodes.rt.health_payload')
local health = require('core.health')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local NODE_ID = 'RT-1'
local STATE = { INIT = 'INIT', AUTONOM = 'AUTONOM', MASTER = 'MASTER', SAFE = 'SAFE' }

-- ── Mock-Peripherals ─────────────────────────────────────────────────────────

local turbine_rpm = 0
local turbine_peripheral = {
  getRotorSpeed = function() return turbine_rpm end,
}
local reactor_temp = 500
local reactor_peripheral = {
  getCasingTemperature = function() return reactor_temp end,
  getFuelTemperature   = function() return reactor_temp end,
}

local modules_registry = {
  ['turbine:T1'] = {
    id = 'turbine:T1', type = 'turbine', state = 'OFF', progress = 0, limits = {},
    name = 'turbine_1', peripheral = turbine_peripheral,
    caps = { setInductorEngaged = true, setFluidFlowRateMax = true },
  },
  ['reactor:R1'] = {
    id = 'reactor:R1', type = 'reactor', state = 'OFF', progress = 0, limits = {},
    name = 'reactor_1', peripheral = reactor_peripheral,
    caps = { setControlRodLevel = true },
  },
}

-- ── Lifecycle-ctx (module_lifecycle-Aufrufe) ───────────────────────────────────
-- Mirrors nodes/rt/main.lua's make_lifecycle_ctx() shape (post-MASTER-P0-Fix):
-- ctx.modules zeigt auf die geteilte modules_registry-Tabelle, Startup-State
-- ist echter, gemeinsam genutzter lokaler State (kein Getter-Stub mehr).

local active_startup_id = nil
local turbine_ctrls = {}
local reactor_ctrls = {}
local applied_rod_calls = {}
local broadcast_calls = {}

local lifecycle_ctx = {
  modules = modules_registry,
  comms = { network = { id = NODE_ID } },
  config = { safety = { max_temperature = 1200, temperature_hysteresis = 5, temperature_trip_samples = 1 } },
  TURBINE_MODE_RAMP = 'RAMP',
  RPM_TOL = 15,
  log = function() end,
  warn_once = function() end,
  warn_unsupported = function() end,
  add_alarm = function() end,
  get_active_startup = function() return active_startup_id end,
  set_active_startup = function(id) active_startup_id = id end,
  ramp_duration = function() return 30 end,
  get_target_rpm = function() return 900 end,
  get_turbine_ctrl = function(name)
    turbine_ctrls[name] = turbine_ctrls[name] or { flow = 0 }
    return turbine_ctrls[name]
  end,
  setTurbineActive = function() return true end,
  update_inductor_for_rpm = function() return true, true end,
  update_turbine_flow_state = function(_, _, ctrl) ctrl.flow = 200; return 200, 'RAMP' end,
  setTurbineFlow = function() return true end,
  setReactorActive = function() return true end,
  ensure_reactor_ctrl = function(name)
    reactor_ctrls[name] = reactor_ctrls[name] or {}
    return reactor_ctrls[name]
  end,
  applyReactorRods = function(level, force, source)
    table.insert(applied_rod_calls, { level = level, force = force, source = source })
  end,
  evaluate_reactor_coolant = function() return { condition = 'OK', triggered = false } end,
}

-- ── Command-ctx (command_handler.lua-Aufrufe) ───────────────────────────────
-- Mirrors nodes/rt/main.lua's build_command_ctx() shape (post-Fix): echter
-- start_module()-Callback statt No-Op.

local current_state_value = STATE.MASTER
local last_command, last_command_ts

local command_ctx = {
  protocol = require('core.protocol'),
  constants = constants,
  STATE = STATE,
  targets = {},
  node_state_machine = nil,
  apply_mode = function() end,
  request_startup_if_needed = function() end,
  start_module = function(module_id, module_type, ramp_profile)
    return module_lifecycle.start_module(lifecycle_ctx, module_id, module_type, ramp_profile)
  end,
  add_alarm = function() end,
  note_master_seen = function() end,
  get_network_id = function() return NODE_ID end,
  get_current_state = function() return current_state_value end,
  get_states = function() return {} end,
  set_last_command = function(v) last_command = v end,
  set_last_command_ts = function(v) last_command_ts = v end,
  get_capacity_learning = function() return nil end,
  log = function() end,
}

local handle_command = command_handler_lib.new(command_ctx)

local function startup_message(module_id, module_type)
  return {
    type = constants.message_types.COMMAND,
    proto_ver = constants.proto_ver,
    sender_id = 'MASTER-1',
    payload = {
      target = NODE_ID,
      command = {
        target = 'STARTUP_STAGE',
        value = { module_id = module_id, module_type = module_type, ramp_profile = 'NORMAL' },
      },
    },
  }
end

-- 1. Turbine wird zuerst gestartet, ueber den echten Command-Handler-Pfad.
local result = handle_command(startup_message('turbine:T1', 'turbine'))
assert_eq(result.ok, true, 'turbine start_module should be accepted')
assert_eq(result.module_id, 'turbine:T1', 'ack should report the started module id')
assert_eq(modules_registry['turbine:T1'].state, 'STARTING', 'turbine should transition to STARTING')

-- 2. Reactor darf NICHT starten, solange die Turbine noch nicht bestaetigt
--    stabil ist (module_lifecycle.start_module's "Startup busy"-Guard).
local blocked = handle_command(startup_message('reactor:R1', 'reactor'))
assert_eq(blocked.ok, false, 'reactor must be rejected while turbine startup is active')
assert_eq(blocked.reason_code, 'STARTUP_REJECTED', 'reactor rejection should be STARTUP_REJECTED')
assert_eq(modules_registry['reactor:R1'].state, 'OFF', 'reactor must remain OFF while blocked')

-- Turbinen-Drehzahl erreicht sofort das Ziel -> process_startup markiert STABLE.
turbine_rpm = 900
module_lifecycle.process_startup(lifecycle_ctx)
assert_eq(modules_registry['turbine:T1'].state, 'STABLE', 'turbine should reach STABLE once at target rpm')
assert_eq(active_startup_id, nil, 'active startup should clear once turbine is stable')

-- Reactor folgt jetzt, NACH bestaetigter Turbinenstabilitaet.
local reactor_result = handle_command(startup_message('reactor:R1', 'reactor'))
assert_eq(reactor_result.ok, true, 'reactor start_module should be accepted once turbine is stable')
assert_eq(modules_registry['reactor:R1'].state, 'STARTING', 'reactor should transition to STARTING')

clock = clock + 100 -- > ramp_duration(30ms) damit progress auf 1 clamped
module_lifecycle.process_startup(lifecycle_ctx)
assert_eq(modules_registry['reactor:R1'].state, 'STABLE', 'reactor should reach STABLE after ramp completes')
assert_true(#applied_rod_calls > 0, 'reactor rod control should have been applied during ramp')

-- 3. Unbekannte Modul-ID wird abgelehnt.
local unknown = handle_command(startup_message('turbine:NOPE', 'turbine'))
assert_eq(unknown.ok, false, 'unknown module id must be rejected')
assert_eq(unknown.reason_code, 'STARTUP_REJECTED', 'unknown module rejection should be STARTUP_REJECTED')

-- 4. SAFE lehnt jeden Startup-Befehl ab (command_handler.lua's globaler
--    SAFE-Guard, VOR jedem Dispatch-Handler).
current_state_value = STATE.SAFE
local safe_result = handle_command(startup_message('turbine:T1', 'turbine'))
assert_eq(safe_result.ok, false, 'SAFE state must reject startup commands')
assert_eq(safe_result.reason_code, 'SAFE_MODE', 'SAFE rejection should use SAFE_MODE reason code')
current_state_value = STATE.MASTER

print('rt_master_startup_end_to_end_test.lua: ok (1-4)')

-- 5. Timeout versetzt den Zielnode in den vorgesehenen degradierten Zustand
--    (startup_diagnostics.handle_startup_timeout, verdrahtet wie in nodes/
--    rt/main.lua's state_ctx.handle_startup_timeout nach dem MASTER-P0-Fix:
--    direkte startup_watchdog_tripped/startup_started_ms-Felder, echtes
--    node_state_machine, broadcast_status()-Callback).

local timeout_transitions = {}
local timeout_node_state_machine = {
  state = function() return constants.node_states.STARTUP end,
  transition = function(_, target) table.insert(timeout_transitions, target) end,
}

local diag_ctx = {
  startup_watchdog_tripped = false,
  startup_started_ms = clock - 90000,
  comms = { network = { id = NODE_ID } },
  config = { role = 'RT', node_id = NODE_ID, safety = { max_temperature = 1200, max_rpm = 1800 } },
  devices = { registry_summary = { total = 2, bound = 2, missing = 0, kinds = { reactor = { bound = 1, total = 1 }, turbine = { bound = 1, total = 1 } } } },
  registry = { get_summary = function() return {} end },
  constants = constants,
  node_state_machine = timeout_node_state_machine,
  log = function() end,
  update_status_snapshot = function() return { max_temp = 400, avg_rpm = 900, turbines = {} } end,
  broadcast_status = function(level) table.insert(broadcast_calls, level) end,
  set_active_startup = function(id) active_startup_id = id end,
  set_startup_queue = function() end,
}

active_startup_id = 'turbine:T1'
local tripped = startup_diagnostics.handle_startup_timeout(diag_ctx)
assert_eq(tripped, true, 'handle_startup_timeout should report the watchdog as tripped')
assert_eq(diag_ctx.startup_watchdog_tripped, true, 'ctx.startup_watchdog_tripped should be set')
assert_eq(active_startup_id, nil, 'active startup should be cleared on timeout')
assert_eq(timeout_transitions[1], constants.node_states.LIMITED, 'non-emergency timeout should degrade to LIMITED')
assert_eq(broadcast_calls[1], constants.status_levels.WARNING, 'timeout should broadcast a WARNING status')

-- Der getrippte Watchdog-Zustand muss auch in die normale Health-Telemetrie
-- durchschlagen (nodes/rt/main.lua's build_status_payload() reicht
-- startup_watchdog_tripped_value jetzt echt durch, statt hart auf false).
local health_ctx = {
  comms = nil, constants = constants,
  master_seen = nil, hb = 5,
  devices = { registry_summary = diag_ctx.devices.registry_summary },
  registry = diag_ctx.registry,
  binding = require('nodes.rt.binding'),
  configured_reactors = {}, configured_turbines = {},
  health = health, warn_once = function() end,
  startup_watchdog_tripped = diag_ctx.startup_watchdog_tripped,
  rt_health = {},
  configured_caps = { reactors = {}, turbines = {} },
}
local built_health = health_payload_lib.build_health_payload(health_ctx)
assert_eq(built_health.status, health.status.DEGRADED, 'tripped watchdog should degrade RT health status')

print('rt_master_startup_end_to_end_test.lua: ok (5)')
