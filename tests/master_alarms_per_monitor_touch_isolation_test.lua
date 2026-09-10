-- Regression test for master/ui/alarms.lua's per-monitor touch-zone bug:
-- hit_zones/footer_hit_zone used to be single module-level variables shared
-- by EVERY session rendering the "Logs" view (primary monitor and any
-- number of AUX monitors, all driven by the same ctx.alarms_ui singleton --
-- see init_runtime.lua's views.alarms). render() for monitor B would
-- overwrite the touch zones monitor A just computed, so a touch on monitor
-- A got checked against monitor B's (unrelated) zones -- ACK/history-cycle
-- worked unreliably or not at all on AUX monitors depending on render order.
--
-- This exercises two distinct "monitors" (plain tables used as identity
-- keys) with two different alert lists and asserts each monitor's touch
-- resolves against its OWN alerts, regardless of render order.

package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

package.loaded['core.ui'] = {
  getSize = function() return 40, 12 end,
  panel = function() end,
  text = function() end,
}
package.loaded['shared.colors'] = { get = function(name) return name end }
package.loaded['master.ui.widgets'] = { fit = function(s, w) return tostring(s or ''):sub(1, w) end }

local alarms = require('master.ui.alarms')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local mon_a, mon_b = {}, {}
local model_a = { active = { { id = 'ALERT-A', severity = 'CRITICAL', title = 'A', ts_first = 1000 } } }
local model_b = { active = {
  { id = 'ALERT-B1', severity = 'WARN', title = 'B1', ts_first = 1000 },
  { id = 'ALERT-B2', severity = 'WARN', title = 'B2', ts_first = 2000 },
} }

-- Render A, then B (B last -- this is the ordering that broke the old
-- shared-state version for a touch on A).
alarms.render(mon_a, model_a)
alarms.render(mon_b, model_b)

-- A touch on monitor A's alarm row must still resolve to monitor A's alert,
-- not whatever monitor B rendered last.
local hit_a = alarms.handle_input(mon_a, 1, 2)
assert(hit_a and hit_a.type == 'alarm_ack', 'monitor A touch should hit an alarm_ack zone')
assert_eq(hit_a.alarm_id, 'ALERT-A', 'monitor A touch must resolve against monitor A\'s own alert')

-- Monitor B's second alert (rows 5-6: header=1, B1 takes rows 2-3, a
-- separator row 4, then B2 at rows 5-6) must resolve to B's alert,
-- independent of render order.
local hit_b = alarms.handle_input(mon_b, 1, 5)
assert(hit_b and hit_b.type == 'alarm_ack', 'monitor B touch should hit an alarm_ack zone')
assert_eq(hit_b.alarm_id, 'ALERT-B2', 'monitor B touch must resolve against monitor B\'s own alert')

-- Footer (history window cycle) touch zones must also stay independent per
-- monitor -- re-render A after B to prove A's zones survive B's render.
alarms.render(mon_a, model_a)
local footer_hit_a = alarms.handle_input(mon_a, 1, 12)
assert(footer_hit_a and footer_hit_a.type == 'history_window_cycle',
  'monitor A footer touch should still cycle the history window after B rendered')

print('master_alarms_per_monitor_touch_isolation_test.lua: ok')
