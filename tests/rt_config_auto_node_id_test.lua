-- Two RT computers used to both default to the literal node_id "RT-1"
-- unless an operator manually edited /xreactor_config/rt.lua, which made
-- the master unable to tell them apart (see xreactor/nodes/rt/config.lua).
-- config.lua now derives the default from os.getComputerID(), the same
-- pattern installer/valve_naming.lua already uses for VALVE -- this test
-- verifies two different computer IDs produce two different default
-- node_ids, and that a missing os.getComputerID() still yields a valid
-- (non-empty) fallback rather than erroring.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local original_os_getComputerID = os.getComputerID

package.loaded['nodes.rt.config'] = nil
os.getComputerID = function() return 7 end
local config_a = require('nodes.rt.config')
assert_eq(config_a.node_id, 'RT-7', 'node_id should derive from computer id 7')

package.loaded['nodes.rt.config'] = nil
os.getComputerID = function() return 23 end
local config_b = require('nodes.rt.config')
assert_eq(config_b.node_id, 'RT-23', 'node_id should derive from computer id 23')

assert(config_a.node_id ~= config_b.node_id, 'two different computer ids must produce two different default node_ids')

package.loaded['nodes.rt.config'] = nil
os.getComputerID = nil
local config_c = require('nodes.rt.config')
assert(type(config_c.node_id) == 'string' and #config_c.node_id > 0,
  'node_id must still be a non-empty string when os.getComputerID is unavailable')

os.getComputerID = original_os_getComputerID
package.loaded['nodes.rt.config'] = nil

print('rt_config_auto_node_id_test.lua: ok')
