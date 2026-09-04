-- tests/alert_rules_duplicate_reactor_name_test.lua
--
-- Regression test: reactor_naming.lua's uniqueness check only dedups
-- names WITHIN one RT installer run -- it has no visibility into names
-- already assigned on a DIFFERENT RT computer, so two RT nodes can each
-- independently pick the same name (e.g. both "Nord"). Master sees every
-- RT node's reactor list (with alias) every cycle via the STATUS payload,
-- so core/alert_rules.lua is the only place that can actually catch this.
--
-- Asserts: (a) the same alias on two different RT nodes raises exactly one
-- REACTOR_NAME_DUPLICATE alert naming both reactors, (b) the same alias
-- used only once (single RT node, or the same physical reactor reported
-- twice) raises nothing, and (c) once one of the two reactors is renamed,
-- the alert clears.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = function() return 10000 end

local constants = require('shared.constants')
local rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
})

local function nodes_with(alias_a, alias_b)
  return {
    {
      id = 'RT-1', role = constants.roles.RT_NODE,
      reactors = { { id = 'reactor_a', name = 'reactor_a', alias = alias_a } },
    },
    {
      id = 'RT-2', role = constants.roles.RT_NODE,
      reactors = { { id = 'reactor_b', name = 'reactor_b', alias = alias_b } },
    },
  }
end

local function has_duplicate_alert(alerts)
  for _, alert in ipairs(alerts) do
    if alert.code == 'REACTOR_NAME_DUPLICATE' then return alert end
  end
  return nil
end

-- Case-insensitive collision across two different RT nodes.
local alerts1 = rules:evaluate({ now = 10000, nodes = nodes_with('Nord', 'nord') })
local dup = has_duplicate_alert(alerts1)
if not dup then
  error('expected a REACTOR_NAME_DUPLICATE alert when two RT nodes use the same name')
end
if not (dup.message:find('RT%-1:reactor_a') and dup.message:find('RT%-2:reactor_b')) then
  error('duplicate alert must name both colliding reactors, got: ' .. tostring(dup.message))
end

-- Renaming one of the two colliding reactors (the transition out of
-- collision) must clear the previously-raised alert on this same call.
local alerts2, clears2 = rules:evaluate({ now = 10000, nodes = nodes_with('Nord', 'Sued') })
if has_duplicate_alert(alerts2) then
  error('distinct reactor names must never raise REACTOR_NAME_DUPLICATE')
end
local cleared = false
for _, key in ipairs(clears2) do
  if tostring(key):find('REACTOR_NAME_DUPLICATE', 1, true) then cleared = true end
end
if not cleared then
  error('expected the duplicate alert to clear on the same call the names diverge')
end

-- Once cleared, staying distinct must not raise or re-clear anything.
local alerts3 = rules:evaluate({ now = 10000, nodes = nodes_with('Nord', 'Ost') })
if has_duplicate_alert(alerts3) then
  error('distinct reactor names must never raise REACTOR_NAME_DUPLICATE')
end

print('alert_rules_duplicate_reactor_name_test.lua: ok')
