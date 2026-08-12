package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.keys = _G.keys or { left = 1, right = 2, pageUp = 3, pageDown = 4 }
_G.os = _G.os or {}
if not os.epoch then
  local now = 0
  os.epoch = function() now = now + 1000; return now end
end

local function reset_modules()
  package.loaded['nodes.rt.monitor_ui'] = nil
  package.loaded['core.ui'] = setmetatable({
    getSize = function() return 20, 10 end,
    panel = function() end,
    badge = function() end,
    text = function() end,
    list = function() end,
  }, { __index = function() return function() end end })
  package.loaded['core.ui_router'] = {
    new = function(opts)
      return {
        render = function(_, target, model)
          opts.pages[1].render(target, model)
        end,
        handle_input = function() end,
      }
    end,
  }
end

local function test_snapshot_prefers_adapter_data()
  reset_modules()
  local monitor_ui = require('nodes.rt.monitor_ui')

  local raw_reactor_calls = 0
  local raw_turbine_calls = 0

  local reactor_adapter = {
    inspect = function(name)
      return { temperature = 777, fuel = 90, active = true, control_rod_level = 22, energy = 12345, waste = 6 }
    end
  }
  local turbine_adapter = {
    inspect = function(name)
      return { rpm = 1800, flow = 2500, active = true, coil_engaged = false }
    end
  }

  local devices = {
    reactors = {
      {
        id = 'R1',
        name = 'reactor_0',
        peripheral = {
          getTemperature = function() raw_reactor_calls = raw_reactor_calls + 1; return 1 end,
          getFuelAmount = function() raw_reactor_calls = raw_reactor_calls + 1; return 1 end,
          getActive = function() raw_reactor_calls = raw_reactor_calls + 1; return false end,
          getControlRodLevel = function() raw_reactor_calls = raw_reactor_calls + 1; return 99 end,
        }
      },
    },
    turbines = {
      {
        id = 'T1',
        name = 'turbine_0',
        peripheral = {
          getActive = function() raw_turbine_calls = raw_turbine_calls + 1; return false end,
          getInductorEngaged = function() raw_turbine_calls = raw_turbine_calls + 1; return true end,
        }
      },
    },
    registry_summary = { kinds = { reactor = { bound = 1 }, turbine = { bound = 1 } } },
  }

  local snapshot = monitor_ui.update_status_snapshot({
    devices = devices,
    registry = { get_summary = function() return devices.registry_summary end },
    comms = { network = { id = 'RT-1' } },
    config = { node_id = 'RT-1' },
    reactor_adapter = reactor_adapter,
    turbine_adapter = turbine_adapter,
    read_turbine_rpm = function() return 10 end,
    read_turbine_flow = function() return 20 end,
    get_device_caps = function() return {} end,
    get_available_steam = function() return 555 end,
  })

  if snapshot.reactors[1].temperature ~= 777 or snapshot.reactors[1].rods ~= 22 then
    error('expected reactor snapshot values from adapter.inspect')
  end
  if snapshot.turbines[1].rpm ~= 1800 or snapshot.turbines[1].flow ~= 2500 then
    error('expected turbine snapshot values from adapter.inspect')
  end
  if raw_reactor_calls ~= 0 then
    error('raw reactor peripheral methods should not be used when adapter inspect works')
  end
  if raw_turbine_calls ~= 0 then
    error('raw turbine peripheral methods should not be used when adapter inspect works')
  end
end

local function test_update_handles_missing_values_without_crash()
  reset_modules()
  local monitor_ui = require('nodes.rt.monitor_ui')
  local ok, err = pcall(function()
    monitor_ui.update({ setTextScale = function() end, getSize = function() return 20, 10 end }, {
      config = { monitor_interval = 0, node_id = 'RT-1' },
      devices = { reactors = {}, turbines = {}, registry_summary = { kinds = { reactor = { bound = 0 }, turbine = { bound = 0 } } } },
      registry = { get_summary = function() return { kinds = { reactor = { bound = 0 }, turbine = { bound = 0 } } } end },
      comms = { get_diagnostics = function() return { peers = {}, metrics = {} } end },
      constants = { roles = { MASTER = 'MASTER' } },
      master_alerts = {},
      current_state = 'AUTONOM',
      configured_reactors = {},
      configured_turbines = {},
      get_target_rpm = function() return 1800 end,
      binding = { build_policy = function() return { allow_all_reactors = true, allow_all_turbines = true } end },
      build_health_payload = function() return { status = 'OK' } end,
      read_turbine_rpm = function() return nil end,
      read_turbine_flow = function() return nil end,
      get_device_caps = function() return {} end,
      get_available_steam = function() return nil end,
      last_status_snapshot = nil,
    })
  end)
  if not ok then
    error('monitor_ui.update should not crash on missing values: ' .. tostring(err))
  end
end

test_snapshot_prefers_adapter_data()
test_update_handles_missing_values_without_crash()
print('rt_monitor_ui_adapter_snapshot_test.lua: ok')
