-- tests/valve_boot_missing_node_id_test.lua
--
-- Regression test: on a genuinely fresh install (no config backup to
-- restore node_id.txt from), the file simply does not exist yet.
-- core/network.lua's resolve_node_id() generates and persists a
-- "node-<computer id>" fallback for it, but only once comms/network.new()
-- runs -- nodes/valve/main.lua constructs its controller (which asserts
-- a non-empty node_id, see nodes/valve/controller.lua:27) BEFORE that,
-- via nodes/support/runtime.lua's init_logging(). Observed in the field
-- as a hard boot crash: "FEHLER: /xreactor/nodes/valve/controller:27:
-- valve controller requires node_id".
--
-- Asserts: (a) utils.read_node_id_or_generate() generates AND PERSISTS a
-- "node-<id>" fallback when the file is missing, matching network.lua's
-- own scheme so a later network.lua call reads back the SAME id instead
-- of generating a second, different one; (b) init_logging() now returns
-- that generated id instead of nil, so valve_controller.new() never sees
-- a missing node_id on a fresh install.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local files = {}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode == 'r' then
      if files[path] == nil then return nil end
      return { readAll = function() return files[path] end, close = function() end }
    end
    return {
      write = function(content) files[path] = content end,
      close = function() end,
    }
  end,
  getDir = function(path) return path:match('^(.*)/[^/]+$') or '' end,
  makeDir = function() end,
  isDir = function() return true end,
}
_G.os = _G.os or {}
os.getComputerID = function() return 74 end
os.epoch = os.epoch or function() return 0 end

local utils = require('core.utils')

-- (a) Missing file: generates AND writes the same "node-<id>" scheme
-- core/network.lua's own fallback uses.
local NODE_ID_PATH = '/xreactor/config/node_id.txt'
if utils.read_node_id(NODE_ID_PATH) ~= nil then
  error('expected no node_id.txt on a fresh install')
end
local generated = utils.read_node_id_or_generate(NODE_ID_PATH)
if generated ~= 'node-74' then
  error("expected generated node id 'node-74', got " .. tostring(generated))
end
if files[NODE_ID_PATH] ~= 'node-74' then
  error('expected the generated node id to be persisted to node_id.txt, so a later ' ..
    'core/network.lua resolve_node_id() call reads back the SAME id')
end

-- Idempotent: a second call reads the now-persisted value back, unchanged.
local second = utils.read_node_id_or_generate(NODE_ID_PATH)
if second ~= 'node-74' then
  error('expected a second call to read back the persisted id, got ' .. tostring(second))
end

-- An existing, real id is never overwritten.
files[NODE_ID_PATH] = 'node-real-existing'
local preserved = utils.read_node_id_or_generate(NODE_ID_PATH)
if preserved ~= 'node-real-existing' then
  error('expected an existing node_id.txt to be preserved, got ' .. tostring(preserved))
end

-- (b) init_logging() must return a usable node_id instead of nil on a
-- fresh install, so nodes/valve/main.lua's valve_controller.new() never
-- sees a missing node_id.
files[NODE_ID_PATH] = nil
local support_runtime = require('nodes.support.runtime')
local node_id = support_runtime.init_logging({
  utils = utils,
  config = {},
  runtime_config = {
    NODE_ID_PATH = NODE_ID_PATH,
    LOG_NAME = 'xr',
    LOG_PREFIX = 'TEST',
  },
  config_meta = {},
  config_warnings = {},
})
if type(node_id) ~= 'string' or node_id == '' then
  error('expected init_logging() to return a non-empty node_id on a fresh install, got ' .. tostring(node_id))
end

print('valve_boot_missing_node_id_test.lua: ok')
