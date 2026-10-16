-- Regression test for the AUX-monitor touch bug: on an unlocked (AUX,
-- monitor 4+) session, only the [<]/[>] view-cycle footer buttons ever
-- reached the active view -- every other touch (e.g. the ACK/MUTE buttons
-- in master/ui/alerts.lua) was silently swallowed because handle_input()
-- returned unconditionally once a session wasn't locked, before ever
-- calling view.hit_test(). AUX sessions are NEVER locked (see
-- monitor_sessions.resolve_locked()), so this made those buttons
-- permanently dead, not just before some "lock" step.

package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

package.loaded['core.ui'] = {
  clear = function() end,
  badge = function() end,
  text = function() end,
  getSize = function() return 80, 24 end,
}
setmetatable(package.loaded['core.ui'], { __index = function() return function() end end })
package.loaded['master.ui.widgets'] = { layout_button = function() end, fit = function(text) return tostring(text or '') end }

local multiview = require('master.ui.multiview')

local hit_test_calls = {}
local action_calls = {}

local m = multiview.new({
  views = {
    overview = { render = function() end },
    rt = { render = function() end },
    energy = { render = function() end },
    alerts = {
      render = function() end,
      hit_test = function(mon, x, y)
        hit_test_calls[#hit_test_calls + 1] = { x = x, y = y }
        return { type = 'alert_ack', id = 'a1' }
      end,
    },
  },
  view_order = { 'overview', 'rt', 'energy', 'alerts' },
  on_action = function(action)
    action_calls[#action_calls + 1] = action
    return true
  end,
})

local monitors = {
  { id = 'M1', name = 'monitor_1', mon = {} },
  { id = 'M2', name = 'monitor_2', mon = {} },
  { id = 'M3', name = 'monitor_3', mon = {} },
  { id = 'M4', name = 'monitor_4', mon = {} },
}

m:render(monitors, { overview = {}, rt = {}, energy = {} })

local sessions = m.sessions:get_sessions()
if sessions[4].locked then error('M4 must stay operator-cyclable') end

-- Switch the AUX monitor onto the "alerts" view so hit_test is reachable.
sessions[4].view_key = 'alerts'

-- A touch away from the [<]/[>] footer buttons (which sit at y=24,
-- x=2..10 and x=71..78 per the 80x24 mocked monitor size) must now reach
-- alerts.hit_test() and dispatch its returned action -- not be swallowed.
m:handle_input('monitor_4', 40, 10)
if #hit_test_calls ~= 1 then error('expected hit_test to be called once, got ' .. #hit_test_calls) end
if #action_calls ~= 1 or action_calls[1].type ~= 'alert_ack' then
  error('expected alert_ack action to be dispatched')
end

-- The nav footer buttons must still cycle the view instead of reaching
-- hit_test (regression check for the existing, working behavior).
m:handle_input('monitor_4', 3, 24)
if #hit_test_calls ~= 1 then error('nav-button touch must not reach hit_test') end
if sessions[4].view_key == 'alerts' then error('[<] touch must cycle the AUX view') end

print('master_multiview_aux_touch_dispatch_test.lua: ok')
