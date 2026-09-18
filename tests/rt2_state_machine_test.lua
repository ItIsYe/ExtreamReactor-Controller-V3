package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Boot sequence: INIT -> LEARNING (hardware found) -> LEARNING holds until
-- capacity is ready, regardless of MASTER connectivity (spec point 1).
do
  local m = rt2_state.new()
  assert_eq(m.current(), rt2_state.states.INIT, 'boots into INIT')

  local s, changed = m.tick({ hardware_ready = false })
  assert_eq(s, rt2_state.states.INIT, 'stays INIT without hardware')
  assert_true(not changed, 'no transition without hardware')

  s, changed = m.tick({ hardware_ready = true, master_connected = true })
  assert_eq(s, rt2_state.states.LEARNING, 'moves to LEARNING once hardware is found')
  assert_true(changed, 'INIT->LEARNING is a real transition')

  -- Still learning, MASTER connected -- must NOT jump to MASTER yet.
  s = m.tick({ hardware_ready = true, master_connected = true, capacity_ready = false })
  assert_eq(s, rt2_state.states.LEARNING, 'learning must complete independently of MASTER presence')

  -- Still learning, MASTER absent -- must also stay in LEARNING (not AUTONOM).
  s = m.tick({ hardware_ready = true, master_connected = false, capacity_ready = false })
  assert_eq(s, rt2_state.states.LEARNING, 'learning is unconditional -- MASTER absence does not skip it either')
end

-- Once learning completes, MASTER presence decides MASTER vs AUTONOM (spec point 2).
do
  local m = rt2_state.new(rt2_state.states.LEARNING)
  local s = m.tick({ capacity_ready = true, master_connected = true })
  assert_eq(s, rt2_state.states.MASTER, 'learning complete + MASTER connected -> MASTER')
end

do
  local m = rt2_state.new(rt2_state.states.LEARNING)
  local s = m.tick({ capacity_ready = true, master_connected = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'learning complete + no MASTER -> AUTONOM')
end

-- Live MASTER connect/disconnect while capacity is already known must
-- flip MASTER<->AUTONOM directly, never back through LEARNING.
do
  local m = rt2_state.new(rt2_state.states.MASTER)
  local s = m.tick({ capacity_ready = true, master_connected = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'MASTER disconnect while running -> AUTONOM directly')
  s = m.tick({ capacity_ready = true, master_connected = true })
  assert_eq(s, rt2_state.states.MASTER, 'MASTER reconnect -> MASTER directly, no relearning')
end

-- Safety trip always wins, from any state, and overrides even a connected MASTER.
do
  local m = rt2_state.new(rt2_state.states.MASTER)
  local s = m.tick({ capacity_ready = true, master_connected = true, safety_tripped = true })
  assert_eq(s, rt2_state.states.SAFE, 'a safety trip must override MASTER connectivity')
end

do
  local m = rt2_state.new(rt2_state.states.LEARNING)
  local s = m.tick({ capacity_ready = false, safety_tripped = true })
  assert_eq(s, rt2_state.states.SAFE, 'a safety trip must override even an incomplete learning phase')
end

-- Recovery from SAFE goes straight to MASTER/AUTONOM (capacity already
-- known), never back through LEARNING.
do
  local m = rt2_state.new(rt2_state.states.SAFE)
  local s = m.tick({ capacity_ready = true, master_connected = true, safety_tripped = false })
  assert_eq(s, rt2_state.states.MASTER, 'SAFE recovery with MASTER connected goes straight to MASTER')
end

do
  local m = rt2_state.new(rt2_state.states.SAFE)
  local s = m.tick({ capacity_ready = true, master_connected = false, safety_tripped = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'SAFE recovery without MASTER goes straight to AUTONOM')
end

-- History records every real transition, in order.
do
  local m = rt2_state.new()
  m.tick({ hardware_ready = true })
  m.tick({ capacity_ready = true, master_connected = false })
  local h = m.history()
  assert_eq(#h, 2, 'two real transitions recorded')
  assert_eq(h[1].from, rt2_state.states.INIT, 'first transition from INIT')
  assert_eq(h[1].to, rt2_state.states.LEARNING, 'first transition to LEARNING')
  assert_eq(h[2].to, rt2_state.states.AUTONOM, 'second transition to AUTONOM')
end

print('rt2_state_machine_test.lua: ok')
