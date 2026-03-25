package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.keys = _G.keys or { left = 1, right = 2, pageUp = 3, pageDown = 4 }
_G.peripheral = _G.peripheral or {
  wrap = function() return nil end,
}

package.loaded['core.ui'] = {
  getSize = function() return 20, 10 end,
  panel = function() end,
  badge = function() end,
  text = function() end,
  list = function() end,
}

package.loaded['core.ui_router'] = {
  new = function(opts)
    return {
      render = function(_, monitor, model)
        opts.pages[1].render(monitor, model)
      end,
      handle_input = function() end,
    }
  end,
}

package.loaded['shared.colors'] = {
  get = function() return 1 end,
}

local monitor_ui = require('nodes.rt.monitor_ui')

local function test_init_uses_find_entry_without_wrap_api()
  local monitor_stub = {
    getSize = function() return 20, 10 end,
    setTextScale = function() end,
  }

  local adapter = {
    find = function(preferred, strategy, scale, log_prefix)
      if preferred ~= 'top' then
        error('preferred monitor name should be forwarded')
      end
      if strategy ~= 'first' then
        error('strategy should default to first for deterministic init')
      end
      if scale ~= 0.5 then
        error('monitor scale should be forwarded to adapter.find')
      end
      if log_prefix ~= 'RT' then
        error('log prefix should be RT')
      end
      return { name = 'top', mon = monitor_stub }
    end,
  }

  local ok, mon_or_err, mon_name = pcall(function()
    return monitor_ui.init(adapter, 'top', 0.5)
  end)

  if not ok then
    error('monitor_ui.init crashed without adapter.wrap: ' .. tostring(mon_or_err))
  end
  if mon_or_err ~= monitor_stub then
    error('monitor_ui.init should return monitor from adapter.find entry')
  end
  if mon_name ~= 'top' then
    error('monitor_ui.init should return selected monitor name as second value')
  end
end

local function test_init_graceful_when_no_monitor_available()
  local adapter = {
    find = function() return nil end,
  }

  local ok, mon_or_err, reason = pcall(function()
    return monitor_ui.init(adapter, 'missing_monitor', 0.5)
  end)

  if not ok then
    error('monitor_ui.init should not crash when monitor cannot be resolved: ' .. tostring(mon_or_err))
  end
  if mon_or_err ~= nil then
    error('monitor_ui.init should return nil monitor when none are available')
  end
  if type(reason) ~= 'string' or reason == '' then
    error('monitor_ui.init should return a human-readable reason when monitor init fails')
  end
end

test_init_uses_find_entry_without_wrap_api()
test_init_graceful_when_no_monitor_available()

print('rt_monitor_ui_init_regression_test.lua: ok')
