package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.utils'] = nil
package.loaded['adapters.monitor'] = nil
package.loaded['core.ui'] = nil
package.loaded['core.monitor_manager'] = nil

_G.fs = _G.fs or {
  exists = function() return false end,
  open = function() return nil end,
  getDir = function() return '' end,
  makeDir = function() end,
}
_G.textutils = _G.textutils or {
  serialize = function() return '{}' end,
  unserialize = function() return nil end,
}
local monitor_adapter = require('adapters.monitor')
local ui = require('core.ui')
local monitor_manager = require('core.monitor_manager')

local function read_file(path)
  local handle, err = io.open(path, 'r')
  if not handle then
    error('failed to read file ' .. tostring(path) .. ': ' .. tostring(err))
  end
  local content = handle:read('*a')
  handle:close()
  return content
end

local function test_monitor_adapter_find_calls_wrapped_getSize_safely()
  local calls = 0
  _G.peripheral = {
    getNames = function() return { 'monitor_1' } end,
    getType = function(name) return name == 'monitor_1' and 'monitor' or nil end,
    isPresent = function(name) return name == 'monitor_1' end,
    wrap = function(name)
      if name ~= 'monitor_1' then return nil end
      return {
        getSize = function(arg1)
          if arg1 ~= nil then
            error('wrapped monitor getSize must not receive implicit self argument')
          end
          calls = calls + 1
          return 80, 24
        end,
        setTextScale = function(value, extra)
          if extra ~= nil then
            error('wrapped monitor setTextScale must not receive an extra self argument')
          end
          if value ~= 0.5 then
            error('expected monitor scale value 0.5 during discovery')
          end
        end,
      }
    end,
  }

  local selected = monitor_adapter.find(nil, 'largest', 0.5, 'TEST')
  if not selected or selected.name ~= 'monitor_1' then
    error('expected monitor discovery to succeed')
  end
  if calls < 1 then
    error('expected wrapped getSize call to execute')
  end
end

local function test_monitor_adapter_avoids_duplicate_scale_for_rewrapped_monitor()
  package.loaded['adapters.monitor'] = nil
  local adapter = require('adapters.monitor')
  local set_calls = 0
  local mon_a = {
    setTextScale = function(value)
      set_calls = set_calls + 1
      if value ~= 0.5 then
        error('expected normalized scale 0.5 for initial monitor set')
      end
    end,
  }
  local mon_b = {
    setTextScale = function()
      set_calls = set_calls + 1
    end,
  }

  adapter.safe_set_scale(mon_a, 'monitor_30', 0.5, 'TEST')
  adapter.safe_set_scale(mon_b, 'monitor_30', 0.5, 'TEST')

  if set_calls ~= 1 then
    error('expected duplicate scale write for same monitor name to be skipped across wraps')
  end
end

local function test_monitor_adapter_reapplies_scale_after_monitor_disappears()
  package.loaded['adapters.monitor'] = nil
  local adapter = require('adapters.monitor')
  local set_calls = 0
  local mon_a = { setTextScale = function() set_calls = set_calls + 1 end }
  local mon_b = { setTextScale = function() set_calls = set_calls + 1 end }

  adapter.sync_names({ 'monitor_30' })
  adapter.safe_set_scale(mon_a, 'monitor_30', 0.5, 'TEST')
  adapter.sync_names({})
  adapter.sync_names({ 'monitor_30' })
  adapter.safe_set_scale(mon_b, 'monitor_30', 0.5, 'TEST')

  if set_calls ~= 2 then
    error('expected scale write to re-apply after monitor disappears and is rediscovered')
  end
end

local function test_ui_setScale_normalizes_and_avoids_duplicate_calls()
  local set_calls = 0
  local mon = {
    setTextScale = function(value, extra)
      set_calls = set_calls + 1
      if extra ~= nil then
        error('ui.setScale must not pass implicit self for wrapped monitor call')
      end
      if value ~= 1.5 then
        error('expected scale rounding to nearest 0.5 value')
      end
    end
  }

  ui.setScale(mon, 1.49)
  ui.setScale(mon, 1.5)

  if set_calls ~= 1 then
    error('expected duplicate normalized scale writes to be skipped')
  end
end

local function test_monitor_manager_term_getSize_without_self_forwarding()
  local original_term = _G.term
  local original_peripheral = _G.peripheral
  local called = 0
  _G.term = {
    getSize = function(arg1)
      if arg1 ~= nil then
        error('term.getSize must not receive implicit self argument')
      end
      called = called + 1
      return 51, 19
    end
  }
  _G.peripheral = {
    getNames = function() return {} end,
    getType = function() return nil end,
  }

  local manager = monitor_manager.new({ node_id = 'TEST' })
  local result = manager:scan()
  if type(result) ~= 'table' or #result ~= 1 or not result[1].is_terminal then
    error('expected terminal fallback monitor entry when no physical monitors exist')
  end
  if called ~= 1 then
    error('expected term.getSize fallback to be called exactly once')
  end

  _G.term = original_term
  _G.peripheral = original_peripheral
end

local function test_runtime_wrapped_call_paths_no_implicit_self_forwarding()
  local rt_main = read_file('xreactor/nodes/rt/main.lua')
  if rt_main:find('obj%[method%]%s*%(%s*obj%s*,', 1) then
    error('rt safe_wrapped_call must not pass obj as implicit self argument')
  end

  local network = read_file('xreactor/core/network.lua')
  if network:find('pcall%(wrapped%.isWireless', 1, true) then
    error('network wrapped isWireless call must use shared wrapped-call helper')
  end
  if network:find('pcall%(modem%.open', 1, true) then
    error('network wrapped modem open must use shared wrapped-call helper')
  end
  if network:find('pcall%(modem%.transmit', 1, true) then
    error('network wrapped modem transmit must use shared wrapped-call helper')
  end
end

test_monitor_adapter_find_calls_wrapped_getSize_safely()
test_monitor_adapter_avoids_duplicate_scale_for_rewrapped_monitor()
test_monitor_adapter_reapplies_scale_after_monitor_disappears()
test_ui_setScale_normalizes_and_avoids_duplicate_calls()
test_monitor_manager_term_getSize_without_self_forwarding()
test_runtime_wrapped_call_paths_no_implicit_self_forwarding()
print('wrapped_peripheral_guard_test.lua: ok')
