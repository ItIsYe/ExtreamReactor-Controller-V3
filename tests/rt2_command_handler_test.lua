package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local handler = require('nodes.rt.rt2_command_handler')
local rt2_state = require('nodes.rt.rt2_state')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end

-- SET_SETPOINTS only succeeds while genuinely in MASTER state -- every
-- rejection returns a real {ok=false, reason_code=...}, never nil (the
-- old false-success bug -- dispatcher turning a nil return into
-- {ok=true} -- has no equivalent construction here: every handler
-- returns a table, always).
do
  local r = handler.handle({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } }, { state = rt2_state.states.AUTONOM })
  assert_true(r.ok == false, 'SET_SETPOINTS outside MASTER state must be rejected')
  assert_eq(r.reason_code, 'INVALID_STATE')
end

do
  local r = handler.handle({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } }, { state = rt2_state.states.MASTER })
  assert_true(r.ok, 'SET_SETPOINTS in MASTER state must succeed')
  assert_eq(r.effects.master_percent, 50)
end

do
  local r = handler.handle({ target = 'SET_SETPOINTS', value = { power_target_percent = 500 } }, { state = rt2_state.states.MASTER })
  assert_true(r.ok == false, 'an out-of-range percent must be rejected')
  assert_eq(r.reason_code, 'INVALID_VALUE')
end

-- SCRAM is always accepted, including while already SAFE (idempotent).
do
  local r1 = handler.handle({ target = 'SCRAM' }, { state = rt2_state.states.MASTER })
  assert_true(r1.ok, 'SCRAM must succeed from MASTER')
  assert_true(r1.effects.manual_safety_trip, 'SCRAM must request a manual safety trip')

  local r2 = handler.handle({ target = 'SCRAM' }, { state = rt2_state.states.SAFE })
  assert_true(r2.ok, 'SCRAM must succeed even while already SAFE (idempotent re-assert)')
end

-- The SAFE blanket block allows only SCRAM through -- everything else is rejected.
do
  local r = handler.handle({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } }, { state = rt2_state.states.SAFE })
  assert_true(r.ok == false, 'non-SCRAM commands must be rejected while SAFE')
  assert_eq(r.reason_code, 'SAFE_MODE')
end

-- SET_MODE/MODE are accepted everywhere as an intentional no-op -- mode
-- is derived from MASTER connectivity, not commanded, so there is
-- nothing for these to set (see module header on why this eliminates
-- the mode-desync bug class by construction).
do
  local r = handler.handle({ target = 'SET_MODE', value = 'MASTER' }, { state = rt2_state.states.AUTONOM })
  assert_true(r.ok, 'SET_MODE must be accepted as a harmless no-op')
  assert_true(next(r.effects) == nil, 'SET_MODE must produce no effects -- there is nothing left for it to change')
end

-- Unknown commands and malformed input are rejected explicitly.
do
  local r = handler.handle({ target = 'NOT_A_REAL_COMMAND' }, { state = rt2_state.states.MASTER })
  assert_true(r.ok == false, 'an unknown command target must be rejected')
  assert_eq(r.reason_code, 'UNSUPPORTED_COMMAND')
end

do
  local r = handler.handle({}, { state = rt2_state.states.MASTER })
  assert_true(r.ok == false, 'a command with no target must be rejected')
  assert_eq(r.reason_code, 'INVALID_COMMAND')
end

-- Regression: SAFE must not be a state with no exit. SCRAM latched
-- manual_safety_trip forever and the SAFE blanket block rejected every
-- other command, so a SCRAMmed node stayed dead until a physical reboot.
do
  local r = handler.handle({ target = 'REQUEST_STARTUP_MODULE' }, { state = rt2_state.states.SAFE })
  assert_true(r.ok, 'the restart command must be accepted while SAFE -- it is the only way back')
  assert_true(r.effects.clear_safety_trip, 'it must clear the manual trip latch')

  local staged = handler.handle({ target = 'STARTUP_STAGE' }, { state = rt2_state.states.SAFE })
  assert_true(staged.ok and staged.effects.clear_safety_trip, 'STARTUP_STAGE must work the same way')
end

-- Everything else stays blocked while SAFE.
do
  local r = handler.handle({ target = 'SET_SETPOINTS', value = { power_target_percent = 50 } },
    { state = rt2_state.states.SAFE })
  assert_true(r.ok == false, 'setpoints must still be blocked while SAFE')
  assert_eq(r.reason_code, 'SAFE_MODE')
end

print('rt2_command_handler_test.lua: ok')
