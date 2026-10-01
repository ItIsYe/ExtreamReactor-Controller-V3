package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betriebsfaelle ueber zwei echt gebootete Rollen (RT + MASTER, echtes
-- Funknetz). Es sind genau die Lagen, die in diesem Projekt gemeldet wurden
-- und die kein Modultest sehen kann, weil sie von der Verbindung ZWISCHEN
-- den Rollen abhaengen:
--
--   1. MASTER verschwindet und kommt zurueck
--   2. Eine Sicherheitsausloesung und die Erholung danach
--   3. Eine Turbine wird abgebaut
--
-- Alle drei verhalten sich heute richtig. Der Test ist das Gelaender dafuer:
-- faellt eine dieser Lagen bei einer kuenftigen Aenderung um, faellt es hier
-- auf und nicht in der Anlage.

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local function setup()
  local rt = plant.new_rt({ turbines = 3, node_id = 'node-101' })
  local master = plant.new_master({ node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local net = bus_lib.new()
  net:attach('RT', rt)
  net:attach('MASTER', master)
  return rt, master, net
end

local function mode(net)
  local status = net:last_message_from('RT', 'STATUS')
  return status and status.payload and status.payload.mode or nil
end

local function total_flow(rt)
  local sum = 0
  for index = 1, 3 do sum = sum + rt.plant.turbines[index].flow end
  return sum
end

local function rejected_commands(net)
  local count = 0
  for _, record in ipairs(net:messages_from('RT', 'ACK_APPLIED')) do
    local result = record.message.payload and record.message.payload.result
    if result and result.ok ~= true then count = count + 1 end
  end
  return count
end

-- ══ 1. MASTER verschwindet und kommt zurueck ════════════════════════════
--
-- Gemeldet wurde beides: eine Node, die nach einem Abbruch dauerhaft in
-- AUTONOM haengen blieb, und eine, die die erste Vorgabe nach der Rueckkehr
-- mit INVALID_STATE ablehnte (woraufhin MASTER einen Modus-Desync annahm).
do
  local rt, _, net = setup()
  net:run(150)

  assert_eq(mode(net), 'MASTER', 'mit verbundenem MASTER muss die Node im Zustand MASTER sein')
  assert_true(total_flow(rt) > 0, 'und die Flotte muss laufen')

  -- MASTER abklemmen: seine Nachrichten werden nicht mehr zugestellt. Die
  -- Node selbst laeuft weiter -- genau wie bei einem Funkausfall.
  local master_entry
  for _, entry in ipairs(net.nodes) do
    if entry.name == 'MASTER' then master_entry = entry end
  end
  local real_deliver = net.deliver
  net.deliver = function(self)
    master_entry.seen_transmitted = #master_entry.env.transmitted
    return real_deliver(self)
  end

  net:run(300)   -- 30 s ohne MASTER; comms.peer_timeout_s ist 20 s
  assert_eq(mode(net), 'AUTONOM',
    'ohne MASTER muss die Node nach AUTONOM fallen')
  assert_true(total_flow(rt) > 0,
    'und dort WEITERLAUFEN -- AUTONOM heisst voller Betrieb, nicht Stillstand')

  -- MASTER wieder anklemmen.
  net.deliver = real_deliver
  net:run(200)
  assert_eq(mode(net), 'MASTER',
    'nach der Rueckkehr muss die Node wieder im Zustand MASTER sein')
  assert_true(total_flow(rt) > 0, 'und weiter regeln')
  assert_eq(rejected_commands(net), 0,
    'kein Kommando darf dabei abgelehnt werden -- ein INVALID_STATE laesst MASTER'
      .. ' einen Modus-Desync annehmen und kostet eine Runde')
end

-- ══ 2. Sicherheitsausloesung und Erholung ═══════════════════════════════
do
  local rt, _, net = setup()
  net:run(150)
  assert_true(total_flow(rt) > 0, 'Vorbedingung: die Flotte laeuft')

  -- Temperatur ueber die Grenze (safety.max_temperature = 2000).
  rt.plant.reactors[1].temperature = 2300
  net:run(120)

  local status = net:last_message_from('RT', 'STATUS')
  assert_eq(status.payload.mode, 'SAFE', 'eine Ausloesung muss in den Zustand SAFE fuehren')
  assert_eq(status.payload.state, 'EMERGENCY',
    'und MASTER als EMERGENCY gemeldet werden (rt2_projection)')
  assert_eq(total_flow(rt), 0, 'der Dampf muss abgestellt sein')
  assert_eq(rt.plant.reactors[1].rods, 100, 'und die Staebe voll eingefahren')

  -- Erholung: die Temperatur faellt wieder.
  rt.plant.reactors[1].temperature = 900
  net:run(200)
  assert_eq(mode(net), 'MASTER',
    'nach der Erholung muss die Node von selbst zurueckkommen')
  assert_true(total_flow(rt) > 0, 'und wieder regeln')
end

-- ══ 3. Eine Turbine wird abgebaut ═══════════════════════════════════════
--
-- Die Turbinenzahl ist das einzige Signal, dem das Einlernen als echter Umbau
-- traut (entprellt, siehe rt2_orchestrator.lua). Danach muss die Anlage neu
-- vermessen werden -- und zu einem ERGEBNIS kommen, sonst bleibt MASTERs
-- Vorgabe wirkungslos.
do
  local rt, _, net = setup()
  net:run(200)

  local before = net:last_message_from('RT', 'STATUS').payload
  assert_eq(before.capacity_total_turbines, 3, 'Vorbedingung: drei Turbinen')
  assert_eq(before.capacity_max, 68400, 'Vorbedingung: 3 x 24000 minus 5 % Reserve')
  assert_eq(before.capacity_ready, true, 'Vorbedingung: eingelernt')

  rt:remove_peripheral('BigReactors-Turbine_3')
  net:run(250)

  local after = net:last_message_from('RT', 'STATUS').payload
  assert_eq(after.capacity_total_turbines, 2,
    'die abgebaute Turbine muss verschwinden')
  assert_eq(after.capacity_ready, true,
    'und das Neu-Vermessen muss zu einem Ergebnis kommen')
  assert_eq(after.capacity_max, 45600,
    'die gemeldete Leistung muss der kleineren Flotte entsprechen'
      .. ' (2 x 24000 minus 5 % Reserve)')
end

print('ok plant_scenarios_test')
