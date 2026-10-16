-- AUX monitors (4th+, operator-cyclable) used to always reopen on the
-- first view in the cycle after a MASTER restart, because monitor_sessions
-- keeps view_key only in memory. This verifies the persisted_view_keys
-- fallback (restores the last view on the very first bind after restart,
-- keyed by the monitor's stable registry id) and the on_aux_view_change
-- callback (fired whenever an operator cycles an AUX monitor's view, so
-- the caller can persist it).

package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local sessions_lib = require('master.monitor_sessions')

-- 1) A fresh boot (no in-memory prior) with a persisted view for M4 must
--    restore that view instead of defaulting to the first in the cycle.
local s = sessions_lib.new({
  view_order = { 'overview', 'rt', 'energy', 'alerts', 'alarms' },
  persisted_view_keys = { M4 = 'alarms' },
})

local monitors = {
  { id = 'M1', name = 'monitor_1', mon = {} },
  { id = 'M2', name = 'monitor_2', mon = {} },
  { id = 'M3', name = 'monitor_3', mon = {} },
  { id = 'M4', name = 'monitor_4', mon = {} },
}

s:bind_or_update(monitors)
local sessions = s:get_sessions()
if sessions[4].view_key ~= 'alarms' then
  error('expected AUX monitor M4 to restore its persisted view "alarms", got: ' .. tostring(sessions[4].view_key))
end

-- An id with no persisted entry must still fall back to the first view in
-- the cycle, same as before this feature existed.
local s2 = sessions_lib.new({
  view_order = { 'overview', 'rt', 'energy', 'alerts', 'alarms' },
  persisted_view_keys = { M9 = 'alarms' }, -- unrelated id
})
s2:bind_or_update(monitors)
local sessions2 = s2:get_sessions()
if sessions2[4].view_key ~= 'overview' then
  error('expected AUX monitor with no persisted entry to default to the first view_order entry "overview", got: ' .. tostring(sessions2[4].view_key))
end

-- A persisted view no longer present in view_order (e.g. a removed page)
-- must not be restored -- falls back to the default like an unknown id.
local s3 = sessions_lib.new({
  view_order = { 'overview', 'rt', 'energy', 'alerts', 'alarms' },
  persisted_view_keys = { M4 = 'removed_page' },
})
s3:bind_or_update(monitors)
local sessions3 = s3:get_sessions()
if sessions3[4].view_key ~= 'overview' then
  error('expected a persisted view no longer in view_order to be ignored, got: ' .. tostring(sessions3[4].view_key))
end

-- 2) Cycling an AUX monitor's view must invoke on_aux_view_change(id, view_key)
-- so the caller (init_runtime.lua) can persist the new choice.
local changes = {}
local s4 = sessions_lib.new({
  view_order = { 'overview', 'rt', 'energy', 'alerts', 'alarms' },
  on_aux_view_change = function(id, view_key) changes[#changes + 1] = { id = id, view_key = view_key } end,
})
s4:bind_or_update(monitors)
local sess4 = s4:get_sessions()
local next_view = s4:cycle_aux_view(sess4[4], 1)
if next_view ~= 'rt' then error('expected cycling forward from "overview" to reach "rt", got: ' .. tostring(next_view)) end
if #changes ~= 1 or changes[1].id ~= 'M4' or changes[1].view_key ~= 'rt' then
  error('expected on_aux_view_change to fire once with (M4, rt)')
end

-- A locked primary monitor must never invoke the persistence callback --
-- it isn't operator-cyclable at all (cycle_aux_view already no-ops for it).
s4:cycle_aux_view(sess4[1], 1)
if #changes ~= 1 then error('cycling a locked primary session must not persist anything') end

print('master_monitor_sessions_aux_view_persistence_test.lua: ok')
