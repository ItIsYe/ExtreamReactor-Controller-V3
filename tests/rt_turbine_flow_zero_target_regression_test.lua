package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (gemeldet 2026-09-18, Monitor-Screenshot node-101):
-- "einige Turbinen bei 2000 RPM bekommen genauso vollen Flow wie welche
-- bei 100 RPM". Root cause: get_turbine_target_rpm() weist Turbinen im
-- "AUS"-Slot der VOLLAST/PUFFER/AUS-Leistungsaufteilung target_rpm=0 zu.
-- overspeed_brake_state() aktiviert absichtlich NIE fuer target_rpm<=0
-- (siehe TARGET_ZERO_NO_BRAKE-Kommentar -- ein frueherer Versuch, die
-- Bremse dort greifen zu lassen, verursachte einen Dauer-Lock). Ohne die
-- Bremse blieb eine AUS-Turbine bei mehreren tausend RPM Ueberdrehzahl
-- komplett auf den normalen, schrittbegrenzten Abwaerts-Ramp angewiesen
-- (max_step_down=250 alle 0.2s) -- bis zu 20-30 Sekunden mit vollem/hohem
-- Flow, waehrend eine andere Turbine mit target_rpm=900 bei gleicher RPM
-- durch die Bremse sofort auf Flow=0 fiel.
--
-- Fix: update_turbine_flow_state() erzwingt jetzt auch fuer target_rpm<=0
-- sofort next_flow=0 (wie die Bremse es fuer echten Overspeed tut), OHNE
-- die Induktionsspule zu engagieren (das war die Ursache des alten
-- Dauer-Locks) -- und alle nachfolgenden Entscheidungsbloecke (Zielband-
-- Trim, Readback-Settle-Hold) respektieren dieses erzwungene flow=0 jetzt
-- genauso wie den echten Overspeed-Bremsfall.

local turbine_control = require('nodes.rt.turbine_control')
local rails = require('core.control_rails')
local turbine_regulator = require('core.turbine_regulator')
local safety = require('core.safety')
local utils = require('core.utils')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end

local function make_ctx()
  return {
    config = { rails = {} },
    CONFIG = { TARGET_RPM = 900, RPM_TOLERANCE = 15, MIN_FLOW = 0, MAX_FLOW = 32000 },
    rails = rails,
    turbine_regulator = turbine_regulator,
    safety = safety,
    utils = utils,
  }
end

-- An "AUS"-slot turbine (target_rpm=0) still spinning at 2000 RPM (residual
-- momentum/steam) with a stale high requested flow from before it was
-- parked -- this must now be forced to 0 immediately, not ramped down over
-- many ticks.
do
  local ctx = make_ctx()
  local ctrl = { requested_flow = 20000, flow = 20000, confirmed_flow = 20000 }
  local requested_flow, mode, decision = turbine_control.update_turbine_flow_state(ctx, 2000, 0, ctrl)
  assert_eq(requested_flow, 0, 'an AUS-slot turbine (target=0) massively overspeeding must be forced to flow=0 immediately')
  assert_eq(mode, 'TARGET_ZERO_FLOW_ZERO', 'mode must reflect the forced-zero decision')
  assert_true(decision.overspeed_brake ~= true, 'the target-zero flow-zero path must NOT engage the overspeed brake coil path (that caused the old repeat-count lock)')
end

-- A REAL overspeed case (target_rpm=900, live 2000 RPM) must still force
-- flow=0 via the actual overspeed brake, unaffected by this fix.
do
  local ctx = make_ctx()
  local ctrl = { requested_flow = 20000, flow = 20000, confirmed_flow = 20000 }
  local requested_flow, mode, decision = turbine_control.update_turbine_flow_state(ctx, 2000, 900, ctrl)
  assert_eq(requested_flow, 0, 'a real overspeed turbine must still be forced to flow=0')
  assert_eq(mode, 'OVERSPEED_BRAKE', 'mode must reflect the real overspeed brake decision')
  assert_true(decision.overspeed_brake == true, 'a real overspeed case must still engage the overspeed brake coil path')
end

-- A turbine correctly at its VOLLAST target (900 RPM, target=900) must
-- keep normal target-band regulation -- this fix must not touch turbines
-- that are not in the AUS slot.
do
  local ctx = make_ctx()
  local ctrl = { requested_flow = 5000, flow = 5000, confirmed_flow = 5000 }
  local requested_flow, mode = turbine_control.update_turbine_flow_state(ctx, 905, 900, ctrl)
  assert_true(mode ~= 'TARGET_ZERO_FLOW_ZERO', 'a turbine with a real positive target must never take the target-zero fast path')
end

print('rt_turbine_flow_zero_target_regression_test.lua: ok')
