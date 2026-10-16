package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- DIE GANZE ANLAGE, wie sie beim Betreiber steht:
--
--   8 RT-Knoten (je 2 Reaktoren, 3 Turbinen)   1 MASTER   1 FUEL
--   1 REPROCESSOR   4 ENERGY   10 VALVE        = 25 Knoten
--
--   16 Reaktoren, vom Betreiber benannt: "Reaktor 1" bis "Reaktor 16".
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
local REACTORS_PER_RT = 2         -- 8 x 2 = die 16 benannten Reaktoren
local CAP_PER_RT = 68400          -- 3 Turbinen a 24000 FE/t minus 5 % Reserve
local FLEET_CAP = RT_COUNT * CAP_PER_RT

-- Baut die ganze Anlage bei einem gegebenen Speicherstand.
local function build_site(fill_ratio)
  local specs, rts = {}, {}
  for index = 1, RT_COUNT do
    -- Die Klarnamen des Betreibers. Die Zuordnung in reactor_names.lua geht
    -- nach PERIPHERIENAME, und CC:Tweaked numeriert je Computer -- auf jedem
    -- Knoten heissen die Reaktoren "BigReactors-Reactor_1"/"_2". Jeder Knoten
    -- braucht deshalb seine EIGENE reactor_names.lua, in der dieselben
    -- Peripherienamen auf andere Klarnamen zeigen.
    local first = (index - 1) * REACTORS_PER_RT + 1
    local env = plant.new_rt({
      computer_id = 100 + index, node_id = 'rt-' .. index,
      turbines = 3, reactors = REACTORS_PER_RT,
      reactor_aliases = { 'Reaktor ' .. first, 'Reaktor ' .. (first + 1) },
      reactor_list = {
        { fuel = 1500 + index * 100, fuel_max = 4000 },
        { fuel = 2500 + index * 50,  fuel_max = 4000 },
      },
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
    assert_eq(#(payload.reactors or {}), REACTORS_PER_RT,
      'RT' .. index .. ' muss BEIDE Reaktoren melden')
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

  -- ── Die 16 benannten Reaktoren ────────────────────────────────────────
  --
  -- Hier liegt die Falle einer Anlage mit mehreren RT-Knoten: der Klarname
  -- ist nur ANZEIGE. Die Kennung, unter der geroutet wird, hasht den
  -- PERIPHERIENAMEN (core/registry.lua's build_device_id) -- und der ist auf
  -- jedem Computer derselbe. Die kurzen Kennungen kollidieren also, nur die
  -- globalen (node:reaktor) sind eindeutig.
  local global_ids, short_ids, named = {}, {}, 0
  for index = 1, RT_COUNT do
    local payload = net:last_message_from('RT' .. index, 'STATUS').payload
    for _, reactor in ipairs(payload.reactors or {}) do
      global_ids[tostring(reactor.global_id)] = true
      short_ids[tostring(reactor.id)] = (short_ids[tostring(reactor.id)] or 0) + 1
      if tostring(reactor.alias):find('Reaktor ', 1, true) then named = named + 1 end
    end
  end

  local distinct_global, distinct_short = 0, 0
  for _ in pairs(global_ids) do distinct_global = distinct_global + 1 end
  for _ in pairs(short_ids) do distinct_short = distinct_short + 1 end

  local total_reactors = RT_COUNT * REACTORS_PER_RT
  assert_eq(distinct_global, total_reactors,
    'alle 16 Reaktoren brauchen eine EIGENE globale Kennung')
  assert_eq(named, total_reactors,
    'und alle 16 muessen ihren Klarnamen aus reactor_names.lua tragen')

  -- Die Klarnamen muessen UNTERSCHIEDLICH sein -- im Betrieb bestaetigt
  -- (die 16 Namen kommen am FUEL-Schirm genau so an, wie sie an den
  -- RT-Knoten vergeben wurden).
  --
  -- Das ist keine Selbstverstaendlichkeit, sondern haengt daran, dass JEDER
  -- RT-Knoten seine EIGENE reactor_names.lua hat. Die Zuordnung dort geht
  -- nach PERIPHERIENAME, und der ist auf jedem Computer
  -- "BigReactors-Reactor_1"/"_2". Liegt auf allen acht Knoten dieselbe
  -- Datei, heissen acht Reaktoren "Reaktor 1" und acht "Reaktor 2" -- am
  -- Router-Schirm ist dann nicht mehr zu unterscheiden, welchen man
  -- einlernt, und eine falsch eingelernte Route sieht voellig normal aus.
  --
  -- Diese Zusicherung haelt den funktionierenden Zustand fest.
  local by_name = {}
  for index = 1, RT_COUNT do
    local payload = net:last_message_from('RT' .. index, 'STATUS').payload
    for _, reactor in ipairs(payload.reactors or {}) do
      local alias = tostring(reactor.alias)
      if by_name[alias] then
        error(string.format(
          'der Klarname %q kommt doppelt vor (%s und %s) -- dann traegt nicht'
            .. ' jeder RT-Knoten seine eigene reactor_names.lua',
          alias, by_name[alias], tostring(reactor.global_id)), 2)
      end
      by_name[alias] = tostring(reactor.global_id)
    end
  end

  local distinct_names = 0
  for _ in pairs(by_name) do distinct_names = distinct_names + 1 end
  assert_eq(distinct_names, total_reactors,
    'alle 16 Reaktoren muessen EINEN EIGENEN Klarnamen haben')

  -- Und jeder Name zeigt auf genau einen Reaktor, auch quer durch die
  -- Brennstoffkette: "Reaktor 7" darf am FUEL-Schirm nicht der Reaktor von
  -- Knoten 3 sein.
  for alias, global_id in pairs(by_name) do
    local node = tostring(global_id):match('^([^:]+):')
    assert_true(node ~= nil, string.format(
      'die globale Kennung von %q muss ihren Knoten nennen (%s)', alias, global_id))
  end

  -- Die kurzen Kennungen sind nur so viele wie Reaktoren JE KNOTEN: die
  -- erste Position aller acht Knoten teilt eine, die zweite eine weitere.
  assert_eq(distinct_short, REACTORS_PER_RT, string.format(
    'die kurzen Kennungen MUESSEN kollidieren (%d verschiedene bei %d Reaktoren)'
      .. ' -- daran haengt, dass eine FUEL-Route die globale Kennung braucht',
    distinct_short, total_reactors))
  for id, count in pairs(short_ids) do
    assert_eq(count, RT_COUNT, string.format(
      'die kurze Kennung %s muss von allen %d Knoten geteilt werden', id, RT_COUNT))
  end

  -- Beide Reaktoren JE KNOTEN werden wirklich gestellt, nicht nur der erste.
  for index = 1, RT_COUNT do
    for slot = 1, REACTORS_PER_RT do
      assert_true(rts[index].plant.reactors[slot].writes > 0, string.format(
        'RT%d Reaktor %d muss gestellt werden -- bei mehreren Reaktoren je Knoten'
          .. ' wurde schon einmal nur der erste geregelt',
        index, slot))
    end
  end

  -- ── Die Brennstoffkette fuer alle 16 ──────────────────────────────────
  local relayed
  for _, record in ipairs(net:messages_from('MASTER', 'COMMAND')) do
    local command = record.message.payload and record.message.payload.command
    if command and command.target == 'FUEL_STATUS' then relayed = command.value end
  end
  assert_true(type(relayed) == 'table', 'MASTER muss die Fuellstaende weitergeben')

  local relayed_global, relayed_short, relayed_named = 0, 0, 0
  for key, entry in pairs(relayed) do
    if tostring(key):find(':', 1, true) then relayed_global = relayed_global + 1
    else relayed_short = relayed_short + 1 end
    if tostring(entry.label):find('Reaktor ', 1, true) then relayed_named = relayed_named + 1 end
  end
  assert_eq(relayed_global, total_reactors,
    'alle 16 Reaktoren muessen unter ihrer globalen Kennung im Relais stehen')
  assert_eq(relayed_short, 0,
    'und kein kollidierender kurzer Alias darf uebrig bleiben')
  assert_eq(relayed_named, total_reactors,
    'FUEL muss die Klarnamen sehen, nicht nur Kennungen -- sonst ist am'
      .. ' Router-Schirm nicht zu unterscheiden, welcher Reaktor gemeint ist')

  -- Und zwar jeden Namen GENAU EINMAL, mit derselben Zuordnung Name ->
  -- Reaktor wie an der RT-Node. Im Betrieb bestaetigt: die Namen kommen am
  -- FUEL-Schirm so an, wie sie an den RT-Knoten vergeben wurden.
  local relayed_by_name = {}
  for key, entry in pairs(relayed) do
    local label = tostring(entry.label)
    assert_true(relayed_by_name[label] == nil, string.format(
      'der Klarname %q darf im Relais nicht doppelt auftauchen (%s und %s)',
      label, tostring(relayed_by_name[label]), tostring(key)))
    relayed_by_name[label] = key
  end
  for alias, global_id in pairs(by_name) do
    assert_eq(relayed_by_name[alias], global_id, string.format(
      '%q muss im Relais auf denselben Reaktor zeigen wie an der RT-Node', alias))
  end

  -- Und die Fuellstaende bleiben je Reaktor getrennt.
  local first_payload = net:last_message_from('RT1', 'STATUS').payload
  for _, reactor in ipairs(first_payload.reactors or {}) do
    local entry = relayed[tostring(reactor.global_id)]
    assert_true(entry ~= nil, 'Reaktor ' .. tostring(reactor.alias) .. ' muss im Relais stehen')
    assert_eq(entry.fuel_amount, reactor.fuel_amount, string.format(
      '%s muss SEINEN Fuellstand tragen', tostring(reactor.alias)))
  end
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
