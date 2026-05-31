package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

package.loaded["master.ui_controller"] = nil
_G.os = _G.os or {}
_G.os.epoch = _G.os.epoch or function() return 10000 end
local ui_controller = require("master.ui_controller")

local captured = nil
local controller = ui_controller.new({
  constants = {
    roles = { ENERGY_NODE = "ENERGY_NODE", RT_NODE = "RT_NODE", WATER_NODE = "WATER_NODE", FUEL_NODE = "FUEL_NODE", REPROCESSOR_NODE = "REPROCESSOR_NODE" },
    status_levels = { OK = "OK", WARNING = "WARNING", EMERGENCY = "EMERGENCY", LIMITED = "LIMITED", OFFLINE = "OFFLINE", MANUAL = "MANUAL" },
    node_states = { OFF = "OFF" }
  },
  health = { reasons_list = function() return {} end, summarize_bindings = function() return nil end },
  config = { energy_warn_pct = 25, energy_crit_pct = 15 },
  nodes = {
    A = { id = "A", role = "ENERGY_NODE", status = "OK", stored = 100, capacity = 200, input = 5, output = 2, matrices = { { id = "a-m" } } },
    B = { id = "B", role = "ENERGY_NODE", status = "OK", stored = 300, capacity = 600, input = 8, output = 4, matrices = { { id = "b-m" } } }
  },
  alarms = {},
  comms = { get_diagnostics = function() return {} end },
  sequencer = { ramp_profile = {}, state = "idle", queue = {}, active = nil },
  alert_service = nil,
  view_manager = {
    render = function(_, _, data)
      captured = data.energy
      return { energy = true }
    end
  },
  trends = { is_dirty = function() return false end, clear_dirty = function() end },
  trend_cache = { energy = {}, energy_arrow = "→" },
  state = { last_draw = 0, power_target = 0, active_profile = "BASELOAD", auto_profile = false, critical_blink_until = 0, monitor_cache = { list = {} } },
  calc = {
    get_power_target = function() return 0 end,
    get_active_profile = function() return "BASELOAD" end,
    get_auto_profile = function() return false end
  }
})

controller.draw()

if not captured then
  error("expected energy view payload to be rendered")
end
if captured.stored ~= 400 or captured.capacity ~= 800 then
  error(("expected aggregation 400/800, got %s/%s"):format(tostring(captured.stored), tostring(captured.capacity)))
end
if #captured.nodes ~= 2 then
  error("expected two aggregated energy nodes")
end

print("master_energy_aggregation_test.lua: ok")
