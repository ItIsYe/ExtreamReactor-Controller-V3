package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.utils'] = nil
package.loaded['adapters.monitor'] = nil
package.loaded['core.ui'] = nil

local monitor_adapter = require('adapters.monitor')
local ui = require('core.ui')

local function test_monitor_adapter_find_calls_wrapped_getSize_safely()
  local calls = 0
  _G.peripheral = {
    getNames = function() return { 'monitor_1' } end,
    getType = function(name) return name == 'monitor_1' and 'monitor' or nil end,
    isPresent = function(name) return name == 'monitor_1' end,
    wrap = function(name)
      if name ~= 'monitor_1' then return nil end
      return {
        getSize = function(self)
          if self == nil then
            error('self should be forwarded for wrapped monitor calls')
          end
          calls = calls + 1
          return 10, 5
        end,
        setTextScale = function() end,
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

local function test_ui_setScale_normalizes_and_avoids_duplicate_calls()
  local set_calls = 0
  local mon = {
    setTextScale = function(_, value)
      set_calls = set_calls + 1
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

test_monitor_adapter_find_calls_wrapped_getSize_safely()
test_ui_setScale_normalizes_and_avoids_duplicate_calls()
print('wrapped_peripheral_guard_test.lua: ok')
