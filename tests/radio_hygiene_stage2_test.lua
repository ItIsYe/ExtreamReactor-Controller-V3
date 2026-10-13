package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Funk-Hygiene Stufe 2 (v822): jede Richtung ihr eigener Kanal.
--
-- Befund (Anlagen-Harness, 3 RT + MASTER + FUEL + REPROCESSOR + ENERGY +
-- 4 VALVE, 60 s, nach Stufe 1): JEDE Node empfing rund 540 Meldungen je
-- Minute, davon rund 410 auf 6501 -- Heartbeats, Status und Quittungen der
-- anderen Nodes, die ausser MASTER und FUEL keine Rolle braucht. CC:Tweaked
-- stellt jede Meldung jedem Computer zu, der ihren Kanal offen hat; was
-- ankommt, belegt die Ereignis-Warteschlange (256), auch wenn es danach
-- sofort verworfen wird.
--
--   6500 Downlink  MASTER -> alle       (jede Node hoert ihn)
--   6501 Uplink    Nodes -> MASTER      (dauerhaft nur MASTER und FUEL)
--   6503 Log       Nodes -> Collector   (nur der Collector)
--   6505 Log-Antwort Collector -> Nodes
--   6504 Ventil    FUEL -> Ventile
--   6506 Ventil-Antwort Ventile -> FUEL (nur FUEL)
--
--   1. Anlage ab v822: RT, ENERGY, REPROCESSOR und Ventile schliessen den
--      Uplink, sobald MASTER auf dem Downlink sendet; danach kommt bei
--      ihnen nichts mehr von 6501 an. MASTER hoert jede Node, FUEL jedes
--      Ventil. Die Quittungen der Nodes gehen auf den Uplink und erreichen
--      MASTER; RT regelt weiter im Zustand MASTER.
--   2. Folge-Nodes fuehren nur MASTER als Peer -- kein "Peer down" fuer
--      Nodes, die sie nach dem Schliessen nicht mehr hoeren.
--   3. Ventilkette: SET_VALVE nennt 6506, die Ventile quittieren dort, nur
--      FUEL hoert es; die Lieferung laeuft.
--   4. MASTER faellt auf das alte Verhalten zurueck (Heartbeat/Status auf
--      6501): nach 30 s ohne MASTER auf dem Downlink oeffnen die Nodes den
--      Uplink wieder und hoeren MASTER; kommt er zurueck, schliessen sie neu.
--   5. MASTER bis v821 von Anfang an: keine Node schliesst den Uplink, alle
--      bleiben mit MASTER verbunden.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local boot = require('support.cc_node_boot')
local constants = require('shared.constants')
local T = constants.message_types
local CH = constants.channels

assert_eq(CH.LOG_REPLY, 6505, 'Log-Antwortkanal')
assert_eq(CH.VALVE_REPLY, 6506, 'Ventil-Antwortkanal')

-- Ein MASTER bis v821: Heartbeat, Status und Alarm auf 6501.
local function make_master_old(env)
  env.services.COMMS._broadcast_channel = function() return CH.STATUS end
end
local function make_master_new(env)
  env.services.COMMS._broadcast_channel = nil
end

local function uplink(env) return env.services.COMMS:get_uplink_state() end

local function window_rx(net, from_index)
  local rx = {}
  for i = from_index + 1, #net.delivered do
    local d = net.delivered[i]
    rx[d.to] = rx[d.to] or { total = 0, by_channel = {}, from = {} }
    local r = rx[d.to]
    r.total = r.total + 1
    r.by_channel[d.channel] = (r.by_channel[d.channel] or 0) + 1
    local m = d.message
    if type(m) == 'table' and m.type then
      local key = d.from .. ':' .. tostring(m.type)
      r.from[key] = (r.from[key] or 0) + 1
    end
  end
  return rx
end

local function sends(env, from_index, pred)
  local out = {}
  for i = from_index + 1, #env.transmitted do
    local t = env.transmitted[i]
    if pred(t.message, t) then out[#out + 1] = t end
  end
  return out
end

-- Die Log-Zeilen, die eine Node gefunkt hat (LOG_EVENT/LOG_EVENT_BATCH auf
-- 6503). env.logs bleibt bei gebooteten Rollen leer: sie laden core.utils
-- ueber ihren eigenen Modulgraphen.
local function radio_log_lines(env, from_index)
  local out = {}
  for i = (from_index or 0) + 1, #env.transmitted do
    local t = env.transmitted[i]
    local m = t.message
    if t.channel == CH.LOG and type(m) == 'table'
        and (m.type == 'LOG_EVENT' or m.type == 'LOG_EVENT_BATCH') then
      for _, e in ipairs(m.entries or { m }) do
        out[#out + 1] = { level = tostring(e.level), message = tostring(e.message) }
      end
    end
  end
  return out
end

local function is_type(...)
  local wanted = {}
  for _, t in ipairs({ ... }) do wanted[t] = true end
  return function(m) return type(m) == 'table' and wanted[m.type] == true end
end

-- ══ Anlage aufbauen ══════════════════════════════════════════════════════════
local rt = plant.new_rt({ computer_id = 101, turbines = 1, node_id = 'node-101',
  reactor = { fuel = 1800, fuel_max = 4000 } })
local master = plant.new_master({ computer_id = 1, node_id = 'master-1' })
plant.boot_all({
  { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
  { name = 'MASTER', env = master, main = 'master/main.lua' },
})
-- Die Reaktor-Kennung fuer FUELs Route lernen.
local learn = bus_lib.new()
learn:attach('RT', rt); learn:attach('MASTER', master)
learn:run(80)
local rt_status = learn:last_message_from('RT', 'STATUS')
local global_id = rt_status and rt_status.payload.reactors[1].global_id
assert_true(global_id ~= nil, 'RT muss die Reaktor-Kennung senden')

local fuel = plant.new_fuel({ computer_id = 202, node_id = 'fuel-1', enabled = true, routes = string.format([[return {
  export_chest = "chest_0",
  reactors = {
    { reactor_id = %q, label = "Reaktor A", path = { "valve-1", "valve-2" },
      request_below = 0.9, fill_amount = 64 },
  },
}]], global_id) })
local function valve(id, computer_id)
  return plant.new_valve({ computer_id = computer_id, node_id = id, config = string.format(
    'return { node_id = %q, redstone_side = "back", trusted_source = "fuel-1" }\n', id) })
end
local v1, v2 = valve('valve-1', 501), valve('valve-2', 502)
local energy = plant.new_energy({ computer_id = 301, node_id = 'energy-1' })
local reproc = plant.new_reprocessor({ computer_id = 400, node_id = 'reproc-1' })

local exports = {}
local real_export = fuel.wrapped['meBridge_0'].exportItem
fuel.wrapped['meBridge_0'].exportItem = function(...)
  exports[#exports + 1] = fuel.clock_ms
  return real_export(...)
end

for _, spec in ipairs({ { fuel, 'nodes/fuel/main.lua' }, { v1, 'nodes/valve/main.lua' },
    { v2, 'nodes/valve/main.lua' }, { energy, 'nodes/energy/main.lua' },
    { reproc, 'nodes/reprocessor/main.lua' } }) do
  boot.reset_module_cache(); spec[1]:activate(); spec[1]:boot(spec[2])
end

local net = bus_lib.new({ raw_channels = { [CH.VALVE] = true, [CH.VALVE_REPLY] = true } })
local envs = { RT = rt, MASTER = master, FUEL = fuel, VALVE1 = v1, VALVE2 = v2, ENERGY = energy, REPROC = reproc }
local order = { 'RT', 'MASTER', 'FUEL', 'VALVE1', 'VALVE2', 'ENERGY', 'REPROC' }
for _, name in ipairs(order) do
  net:attach(name, envs[name])
  -- Was im Lern-Lauf schon zugestellt wurde, nicht noch einmal.
  net:node(name).seen_transmitted = #envs[name].transmitted
end
local followers = { 'RT', 'VALVE1', 'VALVE2', 'ENERGY', 'REPROC' }
local listeners = { 'MASTER', 'FUEL' }

net:run(300)   -- 30 s Anlauf

-- ══ 1. Uplink: zu bei den Folge-Nodes, offen bei MASTER und FUEL ═════════════
for _, name in ipairs(followers) do
  local u = uplink(envs[name])
  assert_eq(u.listen, false, name .. ': braucht den Uplink nicht')
  assert_eq(u.closed, true, name .. ': Uplink geschlossen, nachdem MASTER auf dem Downlink sendet')
  assert_eq(u.closes, 1, name .. ': genau einmal geschlossen')
  assert_eq(u.reopens, 0, name .. ': nie wieder geoeffnet')
  assert_true(u.master_downlink_ms ~= nil, name .. ': MASTER auf dem Downlink gehoert')
end
for _, name in ipairs(listeners) do
  local u = uplink(envs[name])
  assert_eq(u.listen, true, name .. ': hoert den Uplink')
  assert_eq(u.closed, false, name .. ': Uplink bleibt offen')
end

local d0 = #net.delivered
local tx0 = {}
for _, name in ipairs(order) do tx0[name] = #envs[name].transmitted end
local not_heard0 = {}
for _, name in ipairs(order) do not_heard0[name] = net.not_heard[name] or 0 end

net:run(300)   -- 30 s Messfenster

local rx = window_rx(net, d0)
for _, name in ipairs(followers) do
  local r = rx[name] or { total = 0, by_channel = {}, from = {} }
  assert_eq(r.by_channel[CH.STATUS], nil, name .. ': bekommt nichts mehr von 6501')
  assert_true((r.by_channel[CH.CONTROL] or 0) > 0, name .. ': hoert MASTER auf 6500')
  assert_true((net.not_heard[name] or 0) - not_heard0[name] > 0,
    name .. ': Meldungen der anderen Nodes erreichen ihn gar nicht erst')
end
-- MASTER hoert jede Node, FUEL jedes Ventil.
for _, name in ipairs({ 'RT', 'FUEL', 'VALVE1', 'VALVE2', 'ENERGY', 'REPROC' }) do
  assert_true((rx.MASTER.from[name .. ':' .. T.HEARTBEAT] or 0) > 0, 'MASTER hoert ' .. name)
end
assert_true((rx.FUEL.from['VALVE1:' .. T.HEARTBEAT] or 0) > 0, 'FUEL hoert valve-1')
assert_true((rx.FUEL.from['VALVE2:' .. T.HEARTBEAT] or 0) > 0, 'FUEL hoert valve-2')
-- Die Folge-Nodes empfangen nur noch einen Bruchteil dessen, was MASTER hoert.
for _, name in ipairs(followers) do
  assert_true(rx[name].total * 2 < rx.MASTER.total, string.format(
    '%s empfaengt %d, MASTER %d -- erwartet: weniger als die Haelfte', name, rx[name].total, rx.MASTER.total))
end

-- Sender: MASTER auf 6500, alle anderen auf 6501.
local broadcast = is_type(T.HEARTBEAT, T.STATUS, T.HELLO, T.ALERT)
local master_bc = sends(master, tx0.MASTER, broadcast)
assert_true(#master_bc > 0, 'MASTER sendet Heartbeat/Status')
for _, t in ipairs(master_bc) do
  assert_eq(t.channel, CH.CONTROL, 'MASTER ' .. t.message.type .. ' auf dem Downlink')
end
for _, name in ipairs({ 'RT', 'FUEL', 'VALVE1', 'ENERGY', 'REPROC' }) do
  local list = sends(envs[name], tx0[name], broadcast)
  assert_true(#list > 0, name .. ' sendet Heartbeat/Status')
  for _, t in ipairs(list) do
    assert_eq(t.channel, CH.STATUS, name .. ' ' .. t.message.type .. ' auf dem Uplink')
  end
end

-- Quittungen: RT quittiert MASTERs Sollwert-Auffrischung auf dem Uplink,
-- MASTER bekommt sie.
local rt_acks = sends(rt, tx0.RT, is_type(T.ACK_DELIVERED, T.ACK_APPLIED))
assert_true(#rt_acks >= 2, 'RT quittiert (' .. #rt_acks .. ')')
for _, t in ipairs(rt_acks) do assert_eq(t.channel, CH.STATUS, 'RT-Quittung auf dem Uplink') end
assert_true((rx.MASTER.from['RT:' .. T.ACK_APPLIED] or 0) > 0, 'MASTER bekommt RTs ACK_APPLIED')
local timeouts = master.services.COMMS:get_diagnostics().metrics.timeouts
assert_eq(timeouts, 0, 'kein Kommando von MASTER laeuft ins Leere')

-- RT regelt weiter im Zustand MASTER, die Ventile sehen MASTER.
local last_rt = net:last_message_from('RT', 'STATUS')
assert_eq(last_rt and last_rt.payload and last_rt.payload.mode, 'MASTER', 'RT im Zustand MASTER')
assert_true(v1.services.COMMS:is_master_reachable(), 'valve-1 erreicht MASTER')
assert_true(energy.services.COMMS:is_master_reachable(), 'ENERGY erreicht MASTER')

-- ══ 2. Folge-Nodes fuehren nur MASTER als Peer ══════════════════════════════
for _, name in ipairs(followers) do
  local peers = envs[name].services.COMMS:get_peers()
  local count = 0
  for id, peer in pairs(peers) do
    count = count + 1
    assert_eq(peer.role, constants.roles.MASTER, name .. ' fuehrt nur MASTER als Peer, nicht ' .. tostring(id))
  end
  assert_eq(count, 1, name .. ': genau ein Peer')
  local lines = radio_log_lines(envs[name])
  assert_true(#lines > 0, name .. ': funkt Log-Zeilen (sonst prueft das hier nichts)')
  for _, line in ipairs(lines) do
    assert_true(not line.message:find('Peer down', 1, true),
      name .. ': kein "Peer down" fuer Nodes, die er nicht mehr hoert: ' .. line.message)
  end
end
-- FUEL fuehrt weiter jedes Ventil (Ventil-Erreichbarkeit).
local fuel_peers = fuel.services.COMMS:get_peers()
assert_true(fuel_peers['valve-1'] ~= nil and fuel_peers['valve-2'] ~= nil, 'FUEL kennt beide Ventile')

-- ══ 3. Ventilkette ═══════════════════════════════════════════════════════════
local set_valve, ack_reply, ack_old, ack_at_valve = 0, 0, 0, 0
for _, d in ipairs(net.delivered) do
  local m = d.message
  if type(m) == 'table' and m.type == 'SET_VALVE' and d.from == 'FUEL' and d.to == 'VALVE1' then
    set_valve = set_valve + 1
    assert_eq(d.channel, CH.VALVE, 'SET_VALVE auf 6504')
    assert_eq(m.reply_channel, CH.VALVE_REPLY, 'SET_VALVE nennt den Antwortkanal')
  elseif type(m) == 'table' and m.type == 'VALVE_ACK' then
    if d.to == 'FUEL' and d.channel == CH.VALVE_REPLY then ack_reply = ack_reply + 1 end
    if d.channel == CH.VALVE then ack_old = ack_old + 1 end
    if d.to ~= 'FUEL' then ack_at_valve = ack_at_valve + 1 end
  end
end
assert_true(set_valve >= 2, 'FUEL schaltet die Ventile (' .. set_valve .. ')')
assert_true(ack_reply >= 4, 'Quittungen auf 6506 bei FUEL (' .. ack_reply .. ')')
assert_eq(ack_old, 0, 'keine Quittung mehr auf 6504')
assert_eq(ack_at_valve, 0, 'kein Ventil hoert die Quittung eines anderen')
assert_true(#exports >= 1, 'die Lieferung laeuft ueber die Ventilkette')

-- ══ 4. MASTER faellt zurueck: Uplink wieder offen, danach wieder zu ════════════
make_master_old(master)
net:run(250)   -- 25 s: noch innerhalb der 30 s
for _, name in ipairs(followers) do
  assert_eq(uplink(envs[name]).closed, true, name .. ': nach 25 s noch zu (Frist 30 s)')
end
net:run(100)   -- 35 s
for _, name in ipairs(followers) do
  local u = uplink(envs[name])
  assert_eq(u.closed, false, name .. ': nach 30 s ohne MASTER auf dem Downlink wieder offen')
  assert_eq(u.reopens, 1, name .. ': einmal geoeffnet')
end
local d1 = #net.delivered
net:run(100)
local rx1 = window_rx(net, d1)
assert_true((rx1.RT.from['MASTER:' .. T.HEARTBEAT] or 0) > 0, 'RT hoert MASTERs Heartbeat wieder (auf 6501)')
assert_true((rx1.VALVE1.from['MASTER:' .. T.HEARTBEAT] or 0) > 0, 'valve-1 hoert MASTERs Heartbeat wieder')
assert_true(v1.services.COMMS:is_master_reachable(), 'valve-1 erreicht MASTER wieder')

make_master_new(master)
net:run(50)
for _, name in ipairs(followers) do
  local u = uplink(envs[name])
  assert_eq(u.closed, true, name .. ': MASTER wieder auf dem Downlink -> wieder zu')
  assert_eq(u.closes, 2, name .. ': zweimal geschlossen')
end
-- Der erste Wechsel steht im Funk-Log, als INFO. (Die spaeteren koennen
-- im Harness noch im Log-Puffer der Node liegen: der buendelt nach
-- os.clock(), und das ist hier echte Rechenzeit. Gezaehlt wird darum oben
-- ueber get_uplink_state().)
local close_logged = false
for _, line in ipairs(radio_log_lines(rt)) do
  if line.message:find('Uplink-Kanal 6501 geschlossen', 1, true) then
    close_logged = true
    assert_eq(line.level, 'INFO', 'Wechsel als INFO')
  end
end
assert_true(close_logged, 'RT protokolliert das Schliessen')

-- ══ 5. MASTER bis v821 von Anfang an ═════════════════════════════════════════
do
  boot.reset_module_cache()
  local rt_old = plant.new_rt({ computer_id = 111, turbines = 1, node_id = 'rt-11' })
  local master_old = plant.new_master({ computer_id = 2, node_id = 'master-2' })
  local valve_old = plant.new_valve({ computer_id = 511, node_id = 'valve-11' })
  plant.boot_all({
    { name = 'MASTER', env = master_old, main = 'master/main.lua' },
    { name = 'RT', env = rt_old, main = 'nodes/rt/main.lua' },
    { name = 'VALVE', env = valve_old, main = 'nodes/valve/main.lua' },
  })
  make_master_old(master_old)
  local old_net = bus_lib.new()
  old_net:attach('MASTER', master_old); old_net:attach('RT', rt_old); old_net:attach('VALVE', valve_old)
  -- Was MASTER beim Booten schon gesendet hat (Status und Heartbeat auf
  -- 6500, vor der Umstellung oben), sendet ein MASTER bis v821 nie.
  old_net:node('MASTER').seen_transmitted = #master_old.transmitted
  old_net:run(450)   -- 45 s
  for name, env in pairs({ RT = rt_old, VALVE = valve_old }) do
    local u = uplink(env)
    assert_eq(u.closes, 0, name .. ': alter MASTER -- Uplink nie geschlossen')
    assert_eq(u.closed, false, name .. ': Uplink offen')
  end
  local status = old_net:last_message_from('RT', 'STATUS')
  assert_eq(status and status.payload and status.payload.mode, 'MASTER', 'RT mit altem MASTER im Zustand MASTER')
  assert_true(valve_old.services.COMMS:is_master_reachable(), 'Ventil erreicht den alten MASTER')
  local acked = 0
  for _, rec in ipairs(old_net:messages_to('MASTER', T.ACK_APPLIED)) do
    if rec.from == 'RT' then acked = acked + 1 end
  end
  assert_true(acked > 0, 'der alte MASTER bekommt RTs Quittungen (auf 6501, wie er ihn hoert)')
end

print('ok radio_hygiene_stage2_test')
