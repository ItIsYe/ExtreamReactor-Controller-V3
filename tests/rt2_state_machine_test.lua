package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_state = require('nodes.rt.rt2_state')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Der Knoten lernt nichts mehr ein: sobald Hardware da ist, arbeitet er.
do
  local m = rt2_state.new()
  assert_eq(m.current(), rt2_state.states.INIT, 'boots into INIT')

  local s, changed = m.tick({ hardware_ready = false })
  assert_eq(s, rt2_state.states.INIT, 'stays INIT without hardware')
  assert_true(not changed, 'no transition without hardware')

  s, changed = m.tick({ hardware_ready = true, master_connected = true })
  assert_eq(s, rt2_state.states.MASTER, 'hardware + MASTER -> MASTER, no learning phase in between')
  assert_true(changed, 'INIT->MASTER is a real transition')
end

do
  local m = rt2_state.new()
  local s = m.tick({ hardware_ready = true, master_connected = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'hardware without MASTER -> AUTONOM')
end

-- Es gibt keinen Zustand LEARNING mehr, und ein alter, gespeicherter
-- Startzustand darf den Knoten nicht dorthin setzen.
do
  assert_eq(rt2_state.states.LEARNING, nil, 'LEARNING is gone from the vocabulary')
  local m = rt2_state.new('LEARNING')
  assert_eq(m.current(), rt2_state.states.INIT, 'an unknown persisted state falls back to INIT')
end

-- Live MASTER connect/disconnect flips MASTER<->AUTONOM directly.
do
  local m = rt2_state.new(rt2_state.states.MASTER)
  local s = m.tick({ hardware_ready = true, master_connected = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'MASTER disconnect while running -> AUTONOM directly')
  s = m.tick({ hardware_ready = true, master_connected = true })
  assert_eq(s, rt2_state.states.MASTER, 'MASTER reconnect -> MASTER directly')
end

-- Safety trip always wins, from any state, and overrides even a connected MASTER.
do
  local m = rt2_state.new(rt2_state.states.MASTER)
  local s = m.tick({ hardware_ready = true, master_connected = true, safety_tripped = true })
  assert_eq(s, rt2_state.states.SAFE, 'a safety trip must override MASTER connectivity')
end

do
  local m = rt2_state.new(rt2_state.states.INIT)
  local s = m.tick({ hardware_ready = false, safety_tripped = true })
  assert_eq(s, rt2_state.states.SAFE, 'a safety trip wins even before hardware is confirmed')
end

-- Recovery from SAFE goes straight back to MASTER/AUTONOM.
do
  local m = rt2_state.new(rt2_state.states.SAFE)
  local s = m.tick({ hardware_ready = true, master_connected = true, safety_tripped = false })
  assert_eq(s, rt2_state.states.MASTER, 'SAFE recovery with MASTER connected goes straight to MASTER')
end

do
  local m = rt2_state.new(rt2_state.states.SAFE)
  local s = m.tick({ hardware_ready = true, master_connected = false, safety_tripped = false })
  assert_eq(s, rt2_state.states.AUTONOM, 'SAFE recovery without MASTER goes straight to AUTONOM')
end

-- Regression: eine Turbinenzahl, die sich im Betrieb aendert, darf den
-- Knoten nicht mehr aus dem Betrieb werfen. Vorher verwarf rt2_capacity
-- dabei die eingelernte Kapazitaet, der Knoten fiel zurueck ins LEARNING
-- und konnte sich dort nicht mehr einlernen, weil die Flotte unter MASTER
-- auf geteilten Zielen fuhr -- er stand bis zum Neustart. Es gibt jetzt
-- weder eine gelernte Kapazitaet noch einen Weg dorthin zurueck.
do
  assert_eq(rt2_state.decide_next_state('MASTER',
    { hardware_ready = true, master_connected = true }),
    'MASTER', 'a running MASTER node stays operational')
  assert_eq(rt2_state.decide_next_state('AUTONOM',
    { hardware_ready = true, master_connected = false }),
    'AUTONOM', 'a running AUTONOM node stays operational')
  assert_eq(rt2_state.decide_next_state('MASTER',
    { hardware_ready = true, master_connected = true, safety_tripped = true }),
    'SAFE', 'a trip still wins')
end

-- History records every real transition, in order.
do
  local m = rt2_state.new()
  m.tick({ hardware_ready = true, master_connected = false })
  m.tick({ hardware_ready = true, master_connected = true })
  local h = m.history()
  assert_eq(#h, 2, 'two real transitions recorded')
  assert_eq(h[1].from, rt2_state.states.INIT, 'first transition from INIT')
  assert_eq(h[1].to, rt2_state.states.AUTONOM, 'first transition to AUTONOM')
  assert_eq(h[2].to, rt2_state.states.MASTER, 'second transition to MASTER')
end

print('rt2_state_machine_test.lua: ok')
