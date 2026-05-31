package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.fs = _G.fs or {
  exists = function() return false end,
  open = function() return nil end,
  getDir = function() return '' end,
  makeDir = function() end,
  getSize = function() return 0 end,
}
_G.textutils = _G.textutils or {
  serialize = function(value)
    if type(value) ~= 'table' then return tostring(value) end
    return 'table'
  end,
  unserialize = function() return nil end,
}
_G.keys = _G.keys or { left = 1, right = 2, pageUp = 3, pageDown = 4 }
_G.os = _G.os or {}
if not os.epoch then
  local now = 0
  os.epoch = function() now = now + 100; return now end
end
if not os.getComputerID then
  os.getComputerID = function() return 1 end
end
if not os.getComputerLabel then
  os.getComputerLabel = function() return 'CC' end
end

local function reset_module(name)
  package.loaded[name] = nil
end

local function test_multiview_initial_render_without_last_render()
  reset_module('master.ui.multiview')
  package.loaded['core.ui'] = {
    clear = function() end,
    getSize = function() return 20, 8 end,
    text = function() end,
  }
  package.loaded['core.ui_router'] = {
    new = function(_, opts)
      return {
        interval = opts.interval,
        current = function(self)
          return opts.pages[1]
        end,
        render = function(self, target, model)
          opts.pages[1].render(target, model)
        end,
        handle_input = function() return false end,
      }
    end,
  }
  package.loaded['master.ui.widgets'] = {
    layout_button = function() return nil end,
    card = function() end,
  }

  local multiview = require('master.ui.multiview')
  local calls = 0
  local manager = multiview.new({
    views = {
      overview = {
        label = 'Overview',
        interval = 0,
        render = function() calls = calls + 1 end,
      },
    },
    view_order = { 'overview' },
  })

  manager.monitor_states.M1 = {}
  local ok, err = pcall(function()
    manager:render({ { id = 'M1', name = 'monitor_30', mon = { getSize = function() return 20, 8 end }, width = 20, height = 8 } }, {
      overview = { ok = true }
    })
  end)
  if not ok then
    error('multiview render crashed without last_render: ' .. tostring(err))
  end
  if calls < 1 then
    error('multiview did not render initial view')
  end
end

local function test_multiview_render_degrades_on_single_monitor_failure()
  reset_module('master.ui.multiview')
  package.loaded['core.ui'] = {
    clear = function() end,
    getSize = function() return 20, 8 end,
    text = function() end,
  }
  package.loaded['core.ui_router'] = {
    new = function(mon, opts)
      return {
        interval = opts.interval,
        current = function()
          return opts.pages[1]
        end,
        render = function(_, target, model)
          if target and target.fail_render then
            error('simulated monitor render failure')
          end
          opts.pages[1].render(target, model)
        end,
        handle_input = function() return false end,
      }
    end,
  }
  package.loaded['master.ui.widgets'] = {
    layout_button = function() return nil end,
    card = function() end,
  }

  local multiview = require('master.ui.multiview')
  local calls = 0
  local manager = multiview.new({
    views = {
      overview = {
        label = 'Overview',
        interval = 0,
        render = function() calls = calls + 1 end,
      },
    },
    view_order = { 'overview' },
  })

  local ok, err = pcall(function()
    manager:render({
      { id = 'M1', name = 'monitor_30', mon = { getSize = function() return 20, 8 end, fail_render = true }, width = 20, height = 8 },
      { id = 'M2', name = 'monitor_31', mon = { getSize = function() return 20, 8 end }, width = 20, height = 8 },
    }, {
      overview = { ok = true }
    })
  end)
  if not ok then
    error('multiview should continue rendering when one monitor fails: ' .. tostring(err))
  end
  if calls ~= 1 then
    error('expected exactly one successful monitor render, got ' .. tostring(calls))
  end
end

local function test_monitor_scale_requires_number()
  reset_module('adapters.monitor')
  local monitor_adapter = require('adapters.monitor')
  local called_with = nil
  local mon = {
    setTextScale = function(_, scale)
      if type(scale) ~= 'number' then
        error('scale must be numeric')
      end
      called_with = scale
    end,
  }
  local ok = monitor_adapter.safe_set_scale(mon, 'monitor_30', { invalid = true }, 'TEST')
  if ok then
    error('safe_set_scale should reject table scale values')
  end
  if called_with ~= nil then
    error('setTextScale should not be called with invalid scale')
  end
end

local function test_monitor_scale_clamps_and_rounds()
  reset_module('adapters.monitor')
  local monitor_adapter = require('adapters.monitor')
  local called_with = nil
  local mon = {
    setTextScale = function(_, scale)
      called_with = scale
    end,
  }
  local ok, err = monitor_adapter.safe_set_scale(mon, 'monitor_31', 4.74, 'TEST')
  if not ok or err ~= nil then
    error('expected safe_set_scale to accept numeric value')
  end
  if called_with ~= 4.5 then
    error('expected safe_set_scale to round to 0.5 steps, got ' .. tostring(called_with))
  end
end

local function test_network_channel_sanitization_numeric_open()
  reset_module('core.network')
  local opened = {}
  _G.peripheral = {
    isPresent = function(name) return name == 'right' end,
    getType = function(name) return name == 'right' and 'modem' or nil end,
    wrap = function(name)
      if name ~= 'right' then return nil end
      return {
        open = function(channel)
          if type(channel) ~= 'number' then
            error('non numeric channel open')
          end
          table.insert(opened, channel)
        end,
        transmit = function(channel, reply_channel, payload)
          if type(channel) ~= 'number' or type(reply_channel) ~= 'number' or type(payload) ~= 'table' then
            error('invalid transmit signature')
          end
        end,
      }
    end,
  }

  local network = require('core.network')
  local net = network.init({
    wireless_modem = 'right',
    role = 'MASTER',
    channels = {
      control = { channel = 6500 },
      status = { 6501 },
    },
  })

  if not net.modem then
    error('expected modem to initialize with sanitized channels')
  end
  if #opened ~= 2 then
    error('expected exactly two numeric modem.open calls, got ' .. tostring(#opened))
  end
  if type(opened[1]) ~= 'number' or type(opened[2]) ~= 'number' then
    error('modem.open must only receive numeric channels')
  end
  local ok_send, send_err = net:send(6500, { type = 'status', node_id = 'RT-1', role = 'RT_NODE' })
  if not ok_send then
    error('network send should use modem transmit numeric signature: ' .. tostring(send_err))
  end
end

local function test_network_open_rejects_table_channel_runtime()
  reset_module('core.network')
  local opened = 0
  _G.peripheral = {
    isPresent = function(name) return name == 'right' end,
    getType = function(name) return name == 'right' and 'modem' or nil end,
    wrap = function(name)
      if name ~= 'right' then return nil end
      return {
        open = function(channel)
          if type(channel) ~= 'number' then
            error('open called with non-number')
          end
          opened = opened + 1
        end,
        transmit = function() end,
      }
    end,
  }
  local network = require('core.network')
  local net = network.init({
    wireless_modem = 'right',
    role = 'MASTER',
    channels = { control = { bad = true }, status = { bad = true } },
  })
  if net.modem ~= nil then
    error('modem should not initialize when no numeric channels are resolved')
  end
  if opened ~= 0 then
    error('modem.open must not be called when channels are non-numeric')
  end
end

local function test_monitor_scan_skips_scale_failure()
  reset_module('core.monitor_manager')
  package.loaded['core.registry'] = {
    new = function()
      return {
        sync = function() end,
        get_order_index = function() return {} end,
        list = function()
          return {
            { id = 'M1', name = 'monitor_30' },
            { id = 'M2', name = 'monitor_31' },
          }
        end
      }
    end
  }
  package.loaded['adapters.monitor'] = {
    sync_names = function() end,
    safe_set_scale = function(_, name)
      if name == 'monitor_31' then
        return false, 'scale write failed'
      end
      return true
    end
  }
  _G.peripheral = {
    getNames = function() return { 'monitor_30', 'monitor_31' } end,
    getType = function() return 'monitor' end,
    isPresent = function() return true end,
    wrap = function(name)
      return {
        getSize = function() return 20, 8 end
      }
    end,
    getMethods = function() return {} end
  }
  local monitor_manager = require('core.monitor_manager')
  local manager = monitor_manager.new({ scale = 0.5, log_prefix = 'TEST' })
  local monitors = manager:scan()
  if #monitors ~= 1 then
    error('expected one monitor after scale failure degradation, got ' .. tostring(#monitors))
  end
  if monitors[1].name ~= 'monitor_30' then
    error('expected monitor_30 to remain active')
  end
end

local function test_master_main_service_requires_cover_service_new_calls()
  local handle, err = io.open('xreactor/master/main.lua', 'r')
  if not handle then
    error('failed to open xreactor/master/main.lua: ' .. tostring(err))
  end
  local content = handle:read('*a')
  handle:close()

  local required_services = {}
  for local_name, module_name in content:gmatch('local%s+([%w_]+)%s*=%s*require%(%s*["\']([^"\']+)["\']%s*%)') do
    if module_name:match('^services%.') then
      required_services[local_name] = true
    end
  end

  local missing = {}
  for local_name in content:gmatch('([%w_]+)%.new%s*%(') do
    if local_name:match('_service$') and not required_services[local_name] then
      missing[local_name] = true
    end
  end

  local missing_list = {}
  for local_name in pairs(missing) do
    table.insert(missing_list, local_name)
  end
  table.sort(missing_list)

  if #missing_list > 0 then
    error('master/main.lua service used without require: ' .. table.concat(missing_list, ', '))
  end
end

test_multiview_initial_render_without_last_render()
test_multiview_render_degrades_on_single_monitor_failure()
test_monitor_scale_requires_number()
test_monitor_scale_clamps_and_rounds()
test_network_channel_sanitization_numeric_open()
test_network_open_rejects_table_channel_runtime()
test_monitor_scan_skips_scale_failure()
test_master_main_service_requires_cover_service_new_calls()

print('master_regression_guards_test.lua: ok')
