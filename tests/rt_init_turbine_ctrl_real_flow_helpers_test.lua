-- tests/rt_init_turbine_ctrl_real_flow_helpers_test.lua
--
-- Regression test: nodes/rt/turbine_control.lua's M.init_turbine_ctrl() --
-- called unconditionally on every single RT boot (nodes/rt/main.lua's
-- init()) -- called ctx.flow_apply_helpers.reset_log_state(), a method
-- nodes/rt/flow_apply_helpers.lua never defined (it only exports
-- capture_turbine_flow_readback/update_turbine_flow_tracking, both
-- stateless). Observed in the field as a hard boot crash on every RT
-- node: "FEHLER: /xreactor/nodes/rt/turbine_control.lua:233: attempt to
-- call field 'reset_log_state' (a nil value)".
--
-- This went undetected because the one existing test exercising this
-- ctx shape (rt_update_quiesce_hardware_confirmation_test.lua) mocked
-- flow_apply_helpers with a fake reset_log_state -- masking that the
-- REAL module never had one. This test instead requires the REAL
-- flow_apply_helpers module (no mock) and drives M.init_turbine_ctrl()
-- against it directly, so a similar phantom-method call anywhere in
-- this path would fail here again.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local turbine_control = require('nodes.rt.turbine_control')
local flow_apply_helpers = require('nodes.rt.flow_apply_helpers')

local ctx = {
  flow_apply_helpers = flow_apply_helpers, -- the REAL module, not a mock
  turbine_ctrl_store = { stale = true },
  autonom_state = { turbines = { stale = true } },
  config = { turbines = {} },
  binding = {
    missing_devices_message = function() return 'no turbines configured' end,
    build_policy = function() return {} end,
  },
  runtime_config = { configured_reactors = {}, configured_turbines = {} },
  log = function() end,
}

local ok, err = pcall(turbine_control.init_turbine_ctrl, ctx)
if not ok then
  error('init_turbine_ctrl() must not crash against the REAL flow_apply_helpers module: ' .. tostring(err))
end
if next(ctx.turbine_ctrl_store) ~= nil then
  error('expected turbine_ctrl_store to be cleared by init_turbine_ctrl()')
end
if next(ctx.autonom_state.turbines) ~= nil then
  error('expected autonom_state.turbines to be cleared by init_turbine_ctrl()')
end

print('rt_init_turbine_ctrl_real_flow_helpers_test.lua: ok')
