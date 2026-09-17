package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (log analysis 2026-09-16/17: node-53 flapping accompanied
-- by 561 "Node ... reconnected -- COMMS_DOWN alert cleared" log lines within
-- 69 seconds, ~30-33 per node across all 18 known nodes). check_timeouts()'s
-- elseif branch (the "node is currently fine" path) used to run its
-- reconnect log line and alert_service:_clear_alert() call for EVERY
-- healthy node on EVERY pass, regardless of whether COMMS_DOWN had actually
-- been set on that node before -- i.e. every healthy node got logged as
-- "reconnected" on every single check_timeouts() invocation, not just nodes
-- that were actually down and came back. Must now only fire when the node
-- really was down (COMMS_DOWN was set) before this pass clears it.

local constants = require('shared.constants')
local health = require('core.health')
local runtime_ops_rt = require('master.runtime_ops_rt')

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'assert_eq failed') .. ' expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local now = 10000000
local logs = {}
local clear_alert_calls = 0

local function make_runtime(node)
  logs = {}
  clear_alert_calls = 0
  return {
    refs = {
      comms = { get_peers = function() return {} end },
      alert_service = { _clear_alert = function() clear_alert_calls = clear_alert_calls + 1 end },
    },
    config = { comms = { peer_timeout_s = 12, peer_down_grace_s = 2 }, heartbeat_interval = 2 },
    tuning = { node_offline_purge_after_ms = 120000 },
    libs = { constants = constants, health = health },
    log = function(msg) logs[#logs + 1] = msg end,
    state = { nodes = { ['RT-1'] = node } },
  }
end

local real_epoch = os.epoch
os.epoch = function(kind) if kind == 'utc' then return now end return real_epoch(kind) end

-- 1) A perfectly healthy node (never down, no COMMS_DOWN reason ever set)
--    must NOT be logged as "reconnected" on repeated check_timeouts() passes.
local healthy_node = {
  id = 'RT-1', role = 'RT-NODE',
  status = constants.status_levels.OK,
  last_seen = now,
  health = { status = health.status.OK, reasons = {} },
}
local runtime1 = make_runtime(healthy_node)
for _ = 1, 5 do
  runtime_ops_rt.check_timeouts(runtime1)
end
for _, msg in ipairs(logs) do
  if msg:find('reconnected') then
    error('healthy node with no prior COMMS_DOWN must never be logged as reconnected, got: ' .. msg)
  end
end
assert_eq(clear_alert_calls, 0, 'alert_service:_clear_alert() must not be called for a node that was never down')

-- 2) A node that genuinely had COMMS_DOWN set must still be logged as
--    reconnected exactly once when that reason clears, and the alert must
--    actually be cleared.
local recovering_node = {
  id = 'RT-1', role = 'RT-NODE',
  status = constants.status_levels.OK,
  last_seen = now,
  health = { status = health.status.DOWN, reasons = { [health.reasons.COMMS_DOWN] = true } },
}
local runtime2 = make_runtime(recovering_node)
runtime_ops_rt.check_timeouts(runtime2)
local found_reconnect = false
for _, msg in ipairs(logs) do
  if msg:find('reconnected') then found_reconnect = true end
end
if not found_reconnect then error('a node that was actually COMMS_DOWN must be logged as reconnected once it clears') end
assert_eq(clear_alert_calls, 1, 'alert_service:_clear_alert() must be called exactly once for a real reconnect')

-- Second pass on the same (now-healthy) runtime must not log again.
runtime_ops_rt.check_timeouts(runtime2)
local reconnect_count = 0
for _, msg in ipairs(logs) do
  if msg:find('reconnected') then reconnect_count = reconnect_count + 1 end
end
assert_eq(reconnect_count, 1, 'a node must not be logged as reconnected again on subsequent healthy passes')
assert_eq(clear_alert_calls, 1, 'alert_service:_clear_alert() must not be called again on subsequent healthy passes')

os.epoch = real_epoch
print('master_check_timeouts_reconnect_spam_test.lua: ok')
