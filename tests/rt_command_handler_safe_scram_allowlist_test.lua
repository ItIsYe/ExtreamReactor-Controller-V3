package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): command_handler.lua
-- rejected EVERY command target while the node was already in SAFE mode,
-- with no exception -- including SCRAM itself. SCRAM is idempotent
-- (re-applying SAFE changes nothing), so MASTER re-sending it (e.g. after
-- reconnecting to an already-tripped node) must not be reported as
-- "SAFE_MODE: ignoring commands". All other commands must remain blocked.

local constants = require('shared.constants')
local handler = require('nodes.rt.command_handler')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end

local function mk_ctx()
  return {
    protocol = { is_for_node = function() return true end, is_proto_compatible = function() return true end },
    STATE = { MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
    TARGET_RPM = 900,
    targets = {},
    get_current_state = function() return 'SAFE' end,
    get_states = function() return constants.node_states end,
    get_node_state_machine = function() return nil end,
    get_capacity_learning = function() return { ready = false } end,
    request_startup_if_needed = function() end,
    apply_mode = function() end,
    start_module = function() return nil end,
    add_alarm = function() end,
    get_network_id = function() return 'RT-1' end,
    note_master_seen = function() end,
    set_last_command = function() end,
    set_last_command_ts = function() end,
    log = function() end,
  }
end

local function send(ctx, target, value)
  local handle = handler.new(ctx)
  return handle({ proto_ver = constants.proto_ver, payload = { command = { target = target, value = value } } })
end

-- SCRAM while already SAFE must go through, not be blocked as "ignoring commands".
do
  local ctx = mk_ctx()
  local result = send(ctx, 'SCRAM', nil)
  assert_true(result == nil or result.ok ~= false, 'SCRAM while already SAFE must not be rejected as SAFE_MODE')
end

-- Any other command target while SAFE must still be blocked.
do
  local ctx = mk_ctx()
  local result = send(ctx, 'POWER_TARGET', 42)
  assert_true(result and result.ok == false, 'POWER_TARGET while SAFE must still be rejected')
  assert_eq(result.reason_code, 'SAFE_MODE', 'POWER_TARGET while SAFE rejection reason_code')
  assert_eq(ctx.targets.power, nil, 'POWER_TARGET while SAFE must not apply the value')
end

print('rt_command_handler_safe_scram_allowlist_test.lua: ok')
