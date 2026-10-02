package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- DIE GANZE ANLAGE, wie sie beim Betreiber steht:
--
--   8 RT-Knoten (je 1 Reaktor, 3 Turbinen)   1 MASTER   1 FUEL
--   1 REPROCESSOR   4 ENERGY   10 VALVE      = 25 Knoten
--
-- Alle 25 booten WIRKLICH (jede Rolle mit eigenem Modulgraphen) und reden
-- ueber ein echtes Funknetz. Das ist die Pruefung, die kein Modultest und
-- auch kein Ein-Knoten-Test leisten kann:
--
--   * Skaliert die Anmeldung auf 25 Knoten, oder verschluckt sich etwas?
--   * Erreichen ALLE acht RT-Knoten den Zustand MASTER und lernen ein?
--   * Verteilt MASTER die Leistung PROPORTIONAL, oder schaltet er die ganze
--     Flotte ein und aus?
--   * Kommt irgendwo eine Ablehnung oder eine WARN-Zeile?
--
-- Der dritte Punkt ist der wichtigste und der, bei dem eine grobe Messung
-- leicht luegt: bei hohem Speicherstand tragen WENIGE Knoten die Last und die
-- uebrigen stehen. Wer nur den letzten Wert je Knoten ansieht, sieht lauter
-- Nullen und haelt das fuer "alles aus" -- in Wahrheit laufen zwei Knoten auf
-- 80 %. Dieser Test prueft die VERTEILUNG, nicht einen Mittelwert.

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local RT_COUNT, ENERGY_COUNT, VALVE_COUNT = 8, 4, 10
local CAP_PER_RT = 68400          -- 3 Turbinen a 24000 FE/t minus 5 % Reserve
local FLEET_CAP = RT_COUNT * CAP_PER_RT

-- Baut die ganze Anlage bei einem gegebenen Speicherstand.
local function build_site(fill_ratio)
  local specs, rts = {}, {}
  for index = 1, RT_COUNT do
    local env = plant.new_rt({
      computer_id = 100 + index, node_id = 'rt-' .. index,
      turbines = 3, reactors = 1,
      reactor = { fuel = 2600 + index * 50, fuel_max = 4000 },
    })
    rts[index] = env
    specs[#specs + 1] = { name = 'RT' .. index, env = env, main = 'nodes/rt/main.lua' }
  end

  specs[#specs + 1] = { name = 'MASTER',
    env = plant.new_master({ computer_id = 1, node_id = 'master-1' }),
    main = 'master/main.lua' }

  specs[#specs + 1] = { name = 'FUEL',
    env = plant.new_fuel({ computer_id = 202, node_id = 'fuel-1', enabled = true,
      routes = [[return { export_chest = "chest_0", reactors = {} }]] }),
    main = 'nodes/fuel/main.lua' }

  specs[#specs + 1] = { name = 'REPROC',
    env = plant.new_reprocessor({ computer_id = 400, node_id = 'reproc-1' }),
    main = 'nodes/reprocessor/main.lua' }

  for index = 1, ENERGY_COUNT do
    specs[#specs + 1] = { name = 'ENERGY' .. index,
      env = plant.new_energy({ computer_id = 300 + index, node_id = 'energy-' .. index,
        energy = 1.0e10 * fill_ratio, capacity = 1.0e10 }),
      main = 'nodes/energy/main.lua' }
  end

  for index = 1, VALVE_COUNT do
    specs[#specs + 1] = { name = 'VALVE' .. index,
      env = plant.new_valve({ computer_id = 500 + index, node_id = 'valve-' .. index }),
      main = 'nodes/valve/main.lua' }
  end

  plant.boot_all(specs)
  local net = bus_lib.new()
  for _, spec in ipairs(specs) do net:attach(spec.name, spec.env) end
  return net, specs, rts
end

-- Die ZULETZT an jeden RT gesendete Vorgabe, nach Adressat.
--
-- Adressat ist message.dst, nicht die empfangende Node: ein Funkmodem ist ein
-- Rundruf, jede Node bekommt jedes Paket und wirft fremde selbst weg
-- (protocol.is_for_node). Wer hier die empfangende Node nimmt, zaehlt jede
-- Nachricht 24-fach.
local function final_setpoints(net)
  local out = {}
  for _, record in ipairs(net:messages_from('MASTER', 'COMMAND')) do
    local message = record.message
    local command = message.payload and message.payload.command
    if command and command.target == 'SET_SETPOINTS' and message.dst then
      out[tostring(message.dst)] = {
        percent = tonumber(command.value and command.value.power_target_percent),
        state = tostring(command.value and command.value.assignment_state),
      }
    end
  end
  return out
end

local function count_warnings(specs)
  local total, examples = 0, {}
  for _, spec in ipairs(specs) do
    for _, entry in ipairs(spec.env.logs) do
      if entry.level == 'WARN' or entry.level == 'ERROR' then
        total = total + 1
        if #examples < 5 then
          examples[#examples + 1] = spec.name .. ': ' .. entry.message:sub(1, 90)
        end
      end
    end
  end
  return total, table.concat(examples, ' | ')
end

local function count_rejections(net, specs)
  local total, examples = 0, {}
  for _, spec in ipairs(specs) do
    for _, record in ipairs(net:messages_from(spec.name, 'ACK_APPLIED')) do
      local result = record.message.payload and record.message.payload.result
      if result and result.ok ~= true then
        total = total + 1
        if #examples < 5 then
          examples[#examples + 1] = spec.name .. ': '
            .. tostring(result.reason_code or result.error or '?')
        end
      end
    end
  end
  return total, table.concat(examples, ' | ')
end

-- ══ 1. Halb voller Speicher: die ganze Flotte laeuft ════════════════════
do
  local net, specs, rts = build_site(0.50)
  assert_eq(#specs, RT_COUNT + 3 + ENERGY_COUNT + VALVE_COUNT, '25 Knoten muessen gebaut werden')

  net:run(260)

  -- Vorbedingung: es fliesst ueberhaupt Verkehr, und keiner geht verloren.
  assert_true(#net.delivered > 1000, string.format(
    'die Anlage muss reden -- zugestellt wurden nur %d Nachrichten', #net.delivered))
  assert_eq(#net.dropped, 0, 'keine Nachricht darf ohne Empfaenger bleiben')

  -- Alle acht RT-Knoten.
  local in_master, learned, total_capacity = 0, 0, 0
  for index = 1, RT_COUNT do
    local status = net:last_message_from('RT' .. index, 'STATUS')
    assert_true(status ~= nil, 'RT' .. index .. ' muss Status senden')
    local payload = status.payload
    if payload.mode == 'MASTER' then in_master = in_master + 1 end
    if payload.capacity_ready == true then learned = learned + 1 end
    total_capacity = total_capacity + (tonumber(payload.capacity_max) or 0)
    assert_eq(payload.capacity_total_turbines, 3,
      'RT' .. index .. ' muss seine drei Turbinen zaehlen')
  end
  assert_eq(in_master, RT_COUNT, 'alle acht RT-Knoten muessen den Zustand MASTER erreichen')
  assert_eq(learned, RT_COUNT, 'und alle acht muessen einlernen')
  assert_eq(total_capacity, FLEET_CAP,
    'die Summe der gemeldeten Leistung muss der Flotte entsprechen')

  -- Bei halbem Speicher traegt jeder Knoten voll.
  local setpoints = final_setpoints(net)
  for index = 1, RT_COUNT do
    local entry = setpoints['rt-' .. index]
    assert_true(entry ~= nil, 'rt-' .. index .. ' muss eine Vorgabe bekommen')
    assert_eq(entry.percent, 100, string.format(
      'bei halbem Speicher muss rt-%d auf 100 %% stehen (Zustand %s)', index, entry.state))
  end

  -- Und die Hardware folgt wirklich.
  for index = 1, RT_COUNT do
    for turbine = 1, 3 do
      assert_true(rts[index].plant.turbines[turbine].flow > 0, string.format(
        'RT%d Turbine %d muss Durchfluss haben', index, turbine))
    end
  end

  local rejections, rejection_detail = count_rejections(net, specs)
  assert_eq(rejections, 0, 'kein Kommando darf abgelehnt werden -- ' .. rejection_detail)

  local warnings, warning_detail = count_warnings(specs)
  assert_eq(warnings, 0, 'die Anlage darf keine WARN/ERROR melden -- ' .. warning_detail)
end

-- ══ 2. Fast voller Speicher: WENIGE tragen, der Rest steht ═════════════
--
-- Der Kern der Anlagenregelung. MASTER faehrt bei hohem Speicherstand das
-- IDLE-Profil (20 % der Flotte) und verteilt das PROPORTIONAL: nur so viele
-- Knoten, wie dafuer gebraucht werden, und die tragen gemeinsam -- statt
-- alle Knoten ein wenig oder alle gar nicht.
--
-- 0,2 x 547200 = 109440 RF/t. Zwei Knoten (2 x 68400 = 136800) genuegen,
-- also 109440 / 136800 = 80 % fuer diese zwei, der Rest standby/shed.
do
  local net, specs = build_site(0.92)
  net:run(300)

  local setpoints = final_setpoints(net)
  local carrying, standing = {}, {}
  for index = 1, RT_COUNT do
    local entry = setpoints['rt-' .. index]
    assert_true(entry ~= nil, 'rt-' .. index .. ' muss eine Vorgabe bekommen')
    if (entry.percent or 0) > 0 then
      carrying[#carrying + 1] = string.format('rt-%d=%d%%', index, entry.percent)
    else
      standing[#standing + 1] = string.format('rt-%d=%s', index, entry.state)
    end
  end

  assert_true(#carrying > 0, string.format(
    'bei hohem Speicherstand muessen EINZELNE Knoten tragen, nicht alle stehen'
      .. ' -- stehend: %s', table.concat(standing, ' ')))
  assert_true(#carrying < RT_COUNT, string.format(
    'und nicht die ganze Flotte -- tragend: %s', table.concat(carrying, ' ')))

  -- Die tragenden Knoten liegen unter 100 %: das ist die proportionale
  -- Aufteilung. Stuenden sie auf 100 %, waere es wieder alles-oder-nichts.
  for index = 1, RT_COUNT do
    local entry = setpoints['rt-' .. index]
    if (entry.percent or 0) > 0 then
      assert_true(entry.percent < 100, string.format(
        'ein tragender Knoten darf nicht auf 100 %% stehen (rt-%d=%d%%) --'
          .. ' sonst ist die Aufteilung alles-oder-nichts',
        index, entry.percent))
      assert_eq(entry.state, 'active', 'ein tragender Knoten ist active')
    end
  end

  -- Die stehenden Knoten sind ausdruecklich abgeworfen, nicht einfach "0".
  local shed_states = 0
  for index = 1, RT_COUNT do
    local entry = setpoints['rt-' .. index]
    if (entry.percent or 0) == 0 then
      -- standby/shed/shutdown: alle drei heissen "traegt gerade nicht".
      -- shutdown ist der geordnete Abschaltablauf (runtime_ops_rt.lua's
      -- shutdown_workflow), standby der bereitgehaltene Platz, shed der
      -- abgeworfene. Entscheidend ist, dass es ein BENANNTER Zustand ist und
      -- nicht nur eine Null ohne Begruendung.
      assert_true(entry.state == 'standby' or entry.state == 'shed'
        or entry.state == 'shutdown', string.format(
        'ein stehender Knoten muss standby, shed oder shutdown sein, rt-%d ist %s',
        index, entry.state))
      shed_states = shed_states + 1
    end
  end
  assert_true(shed_states > 0, 'mindestens ein Knoten muss abgeworfen sein')

  local rejections, rejection_detail = count_rejections(net, specs)
  assert_eq(rejections, 0, 'auch beim Abwerfen darf nichts abgelehnt werden -- ' .. rejection_detail)
end

print('ok plant_full_site_test')
