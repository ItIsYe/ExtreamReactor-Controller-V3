package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-15: "man merkt dass das ganze System
-- langsamer wird" over a long play session). check_timeouts()'s stale-node
-- purge used to only flag node.managed=false/node.active=false -- the
-- entry itself stayed in runtime.state.nodes FOREVER. That table is
-- iterated in full every tick by ui_controller.lua, rt_sync.lua,
-- alert_rules.lua, housekeeping.lua and every AUX monitor view, so every
-- node ever seen (including PROTO_MISMATCH ghost entries and nodes
-- rebooted with a changed node_id) permanently added iteration cost that
-- never went away. Must now actually be removed from the table once
-- long-offline (node_offline_purge_after_ms), same retention-then-delete
-- pattern core/comms.lua already uses for its own peer table.

local constants = require('shared.constants')
local health = require('core.health')
local runtime_ops_rt = require('master.runtime_ops_rt')

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end
local function assert_nil(v, msg) if v ~= nil then error((msg or 'assert_nil failed') .. ' got=' .. tostring(v)) end end

local now = 10000000
local logs = {}

local function make_runtime(node_last_seen)
  return {
    refs = { comms = { get_peers = function() return {} end } }, -- no live peer entry -> falls back to last_seen path
    config = { comms = { peer_timeout_s = 12, peer_down_grace_s = 2 }, heartbeat_interval = 2 },
    tuning = { node_offline_purge_after_ms = 120000 },
    libs = { constants = constants, health = health },
    log = function(msg) logs[#logs + 1] = msg end,
    state = {
      nodes = {
        ['RT-99'] = {
          id = 'RT-99', role = 'RT-NODE',
          status = constants.status_levels.OK,
          last_seen = node_last_seen,
        },
      },
    },
  }
end

-- Patch os.epoch so the module's own "now = os.epoch('utc')" calls see our
-- controlled clock instead of the real one.
local real_epoch = os.epoch
os.epoch = function(kind) if kind == 'utc' then return now end return real_epoch(kind) end

-- 1) Node goes offline (last_seen far in the past, beyond timeout+grace)
--    but NOT yet past node_offline_purge_after_ms -- must be marked
--    OFFLINE but the entry must still exist (not purged yet).
local runtime1 = make_runtime(now - 20000)
runtime_ops_rt.check_timeouts(runtime1)
assert_true(runtime1.state.nodes['RT-99'] ~= nil, 'node must still exist right after going offline (not yet past purge grace)')
assert_true(runtime1.state.nodes['RT-99'].status == constants.status_levels.OFFLINE, 'node must be marked OFFLINE')

-- 2) Node has been offline for longer than node_offline_purge_after_ms --
--    the entry itself must now be REMOVED from runtime.state.nodes, not
--    just flagged.
local runtime2 = make_runtime(now - 200000)
runtime_ops_rt.check_timeouts(runtime2)
assert_nil(runtime2.state.nodes['RT-99'], 'long-offline node entry must be actually removed from runtime.state.nodes, not just flagged managed=false')

os.epoch = real_epoch
print('master_check_timeouts_node_purge_test.lua: ok')
