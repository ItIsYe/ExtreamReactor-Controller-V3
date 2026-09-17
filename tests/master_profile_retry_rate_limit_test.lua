package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (log evidence 2026-09-17): message_handlers.lua calls
-- retry_pending_profile() on EVERY incoming STATUS message once some RT
-- node has ever reported capacity_max > 0 while power_target is still 0
-- -- without checking whether that node is still available (that check
-- only lives inside estimate_base_power()/node_available()). A node that
-- learned capacity once and then went stale/offline keeps its cached
-- capacity_max > 0 forever, so the trigger condition in message_handlers.lua
-- stays permanently satisfied even though estimate_base_power() correctly
-- excludes that node and keeps returning 0. With a dozen+ nodes sending
-- STATUS every couple seconds, this fired retry_pending_profile() (and
-- therefore a full apply_profile()/estimate_base_power() sweep over every
-- node) continuously, logging "Profile applied: BASELOAD" + "target
-- unchanged at 0.00" roughly every 2 seconds for minutes on end --
-- confirmed contributing to "Service manager tick slow" in the same
-- window (a self-reinforcing spiral: slow tick -> more peer-down ->
-- more retry-triggering STATUS messages).
--
-- Fix: retry_pending_profile() now enforces a minimum interval between
-- actual retry attempts (PROFILE_RETRY_MIN_INTERVAL_MS), regardless of how
-- often it is called. This test drives the real module directly (no os
-- mock needed beyond os.epoch, which the test runner's Lua provides via
-- CC-shim or falls back to 0 consistently within a single test run).

local profile = require('master.runtime_ops_profile')

local function assert_eq(a, b, m) if a ~= b then error((m or 'assert_eq') .. ': expected=' .. tostring(b) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Fake os.epoch so the test controls "now" deterministically instead of
-- depending on wall-clock timing.
local fake_now = 1000000
_G.os = _G.os or {}
os.epoch = function() return fake_now end

local applied_count = 0
local runtime = {
  libs = { profiles = { BASELOAD = { target = 0.6, ramp = 'SLOW' } } },
  log = function() end,
  refs = { sequencer = {} },
  state = {
    power_target = 0,
    pending_profile_retry = 'BASELOAD',
    nodes = {}, -- no nodes at all -> estimate_base_power() always returns 0
  },
}

-- Wrap apply_profile via a counting log to detect how many times it
-- actually ran (it always logs, success or failure).
local original_log = runtime.log
runtime.log = function(msg, level)
  if tostring(msg):find('^Profile applied:', 1, false) then
    applied_count = applied_count + 1
  end
  original_log(msg, level)
end

-- 1) First call must actually attempt the retry (no prior retry timestamp).
profile.retry_pending_profile(runtime)
assert_eq(applied_count, 1, 'first retry call must actually invoke apply_profile()')
-- Still 0 power_target (no nodes), so pending_profile_retry gets re-armed
-- by apply_profile() itself.
assert_eq(runtime.state.pending_profile_retry, 'BASELOAD', 'apply_profile must re-arm the pending retry on continued failure')

-- 2) Many rapid subsequent calls (simulating a burst of STATUS messages
--    arriving within milliseconds of each other) must NOT trigger another
--    attempt before PROFILE_RETRY_MIN_INTERVAL_MS has elapsed.
for _ = 1, 50 do
  profile.retry_pending_profile(runtime)
end
assert_eq(applied_count, 1, 'rapid repeated calls within the rate-limit window must not re-trigger apply_profile()')

-- 3) Once the minimum interval has elapsed, the next call must retry again.
fake_now = fake_now + 5001
profile.retry_pending_profile(runtime)
assert_eq(applied_count, 2, 'a call after the rate-limit window has elapsed must retry again')

-- 4) Once power_target becomes positive, the pending retry is cleared
--    immediately regardless of the rate limit, and no further apply_profile
--    call happens.
runtime.state.power_target = 42
runtime.state.pending_profile_retry = 'BASELOAD'
profile.retry_pending_profile(runtime)
assert_true(runtime.state.pending_profile_retry == nil, 'a positive power_target must clear the pending retry immediately')
assert_eq(applied_count, 2, 'clearing on a positive power_target must not itself invoke apply_profile()')

print('master_profile_retry_rate_limit_test.lua: ok')
