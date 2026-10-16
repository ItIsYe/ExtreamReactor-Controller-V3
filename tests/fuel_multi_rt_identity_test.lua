package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- In einer Anlage mit MEHREREN RT-Knoten ist die KURZE Reaktor-Kennung
-- nicht eindeutig.
--
-- Der Grund liegt in CC:Tweaked: Peripherien werden JE COMPUTER numeriert.
-- Der erste Reaktor heisst auf jedem RT-Computer "BigReactors-Reactor_1", und
-- core/registry.lua's build_device_id() hasht genau diesen Namen (plus Typ und
-- Methodensignatur). Acht RT-Knoten liefern damit ACHT MAL dieselbe kurze
-- Kennung -- nachgemessen unten.
--
-- Der KLARNAME des Betreibers ("Reaktor 1" bis "Reaktor 16" aus
-- reactor_names.lua) aendert daran NICHTS: er ist Anzeige, er geht nicht in
-- den Hash ein. Zwei Reaktoren auf EINEM Knoten unterscheiden sich (andere
-- Peripherienamen), zwei Reaktoren derselben POSITION auf verschiedenen
-- Knoten nicht.
--
-- master/fuel_relay.lua erkennt das und laesst den kurzen Alias dann
-- ausdruecklich WEG ("On collision the alias is removed, preventing an
-- arbitrary node from receiving the route"). Das ist richtig: sonst bekaeme
-- ein beliebiger Knoten die Lieferung.
--
-- Die Folge fuer den Betrieb, und darum steht dieser Test hier: eine
-- FUEL-Route mit der KURZEN Kennung funktioniert in einer Anlage mit EINEM
-- RT-Knoten und hoert in dem Moment auf zu funktionieren, in dem ein zweiter
-- Knoten mit gleichnamigem Reaktor dazukommt. Von aussen sieht das aus wie
-- "es lief, und nach dem Ausbau lief es nicht mehr".
--
-- Richtig ist die GLOBALE Kennung (node:reaktor). Das Einlernen am
-- Router-Schirm nimmt sie auch (nodes/fuel/reactor_targets.lua's
-- add_from_cache liest global_reactor_id) -- betroffen sind nur alte oder von
-- Hand eingetragene Routen. Fuer die meldet der Schirm jetzt "Kennung
-- unbekannt" (siehe fuel_stale_reactor_id_test.lua).

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local fuel_relay = require('master.fuel_relay')
local constants = require('shared.constants')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

-- ══ 1. Die kurzen Kennungen KOLLIDIEREN wirklich ════════════════════════
--
-- Nicht behauptet, sondern an zwei echt gebooteten RT-Knoten gemessen.
local short_ids, global_ids = {}, {}
do
  local specs = {}
  for index = 1, 2 do
    specs[#specs + 1] = {
      name = 'RT' .. index,
      env = plant.new_rt({ computer_id = 100 + index, node_id = 'rt-' .. index, turbines = 1 }),
      main = 'nodes/rt/main.lua',
    }
  end
  specs[#specs + 1] = {
    name = 'MASTER',
    env = plant.new_master({ computer_id = 1, node_id = 'master-1' }),
    main = 'master/main.lua',
  }
  plant.boot_all(specs)

  local net = bus_lib.new()
  for _, spec in ipairs(specs) do net:attach(spec.name, spec.env) end
  net:run(120)

  for index = 1, 2 do
    local status = net:last_message_from('RT' .. index, 'STATUS')
    assert_true(status ~= nil, 'RT' .. index .. ' muss Status senden')
    local reactor = (status.payload.reactors or {})[1]
    assert_true(reactor ~= nil, 'RT' .. index .. ' muss seinen Reaktor melden')
    short_ids[index] = reactor.id
    global_ids[index] = reactor.global_id
  end

  assert_eq(short_ids[1], short_ids[2], string.format(
    'die KURZEN Kennungen muessen kollidieren (%s / %s) -- daran haengt alles'
      .. ' Weitere; waere das nicht so, waere dieser Test gegenstandslos',
    tostring(short_ids[1]), tostring(short_ids[2])))

  assert_true(global_ids[1] ~= global_ids[2], string.format(
    'die GLOBALEN Kennungen muessen sich unterscheiden (%s / %s)',
    tostring(global_ids[1]), tostring(global_ids[2])))
  assert_true(tostring(global_ids[1]):find('rt-1', 1, true) ~= nil,
    'die globale Kennung muss den Knoten enthalten')
end

-- ══ 2. Das Relais laesst den kollidierenden Alias WEG ═══════════════════
do
  local now = 1700000000000
  os.epoch = function() return now end

  local function runtime_with(nodes)
    return {
      libs = { constants = constants },
      state = { nodes = nodes },
    }
  end

  local function rt_node(id, reactor_id, fuel)
    return {
      id = id, role = constants.roles.RT_NODE, last_seen = now,
      stale = false, offline = false,
      rt = { reactors = { {
        id = reactor_id, name = 'BigReactors-Reactor_1',
        fuel_amount = fuel, fuel_capacity = 4000,
      } } },
    }
  end

  -- EIN Knoten: der kurze Alias bleibt -- eine alte Route laeuft weiter.
  local single = fuel_relay._collect_reactor_fuel(runtime_with({
    ['rt-1'] = rt_node('rt-1', short_ids[1], 1800),
  }))
  assert_true(single['rt-1:' .. short_ids[1]] ~= nil,
    'bei einem Knoten muss die globale Kennung vorliegen')
  assert_true(single[short_ids[1]] ~= nil,
    'und der kurze Alias ebenfalls -- Routen aelteren Datums laufen weiter')

  -- ZWEI Knoten mit derselben kurzen Kennung: der Alias faellt weg.
  local pair = fuel_relay._collect_reactor_fuel(runtime_with({
    ['rt-1'] = rt_node('rt-1', short_ids[1], 1800),
    ['rt-2'] = rt_node('rt-2', short_ids[1], 2400),
  }))
  assert_true(pair['rt-1:' .. short_ids[1]] ~= nil, 'beide globalen Kennungen muessen vorliegen')
  assert_true(pair['rt-2:' .. short_ids[1]] ~= nil, 'auch die des zweiten Knotens')
  assert_eq(pair[short_ids[1]], nil,
    'der kollidierende kurze Alias MUSS wegfallen -- sonst bekaeme ein'
      .. ' beliebiger Knoten die Lieferung')

  -- Und die Fuellstaende bleiben je Knoten getrennt.
  assert_eq(pair['rt-1:' .. short_ids[1]].fuel_amount, 1800, 'Fuellstand von rt-1')
  assert_eq(pair['rt-2:' .. short_ids[1]].fuel_amount, 2400, 'Fuellstand von rt-2')
end

-- ══ 3. Acht Knoten: acht globale Kennungen, kein Alias ═════════════════
--
-- Die Groesse der Anlage des Betreibers. Hier muss die Buchfuehrung
-- vollstaendig und eindeutig sein.
do
  local now = 1700000000000
  os.epoch = function() return now end

  local nodes = {}
  for index = 1, 8 do
    nodes['rt-' .. index] = {
      id = 'rt-' .. index, role = constants.roles.RT_NODE, last_seen = now,
      stale = false, offline = false,
      rt = { reactors = { {
        id = short_ids[1], name = 'BigReactors-Reactor_1',
        fuel_amount = 1000 + index * 100, fuel_capacity = 4000,
      } } },
    }
  end

  local snapshot = fuel_relay._collect_reactor_fuel({
    libs = { constants = constants }, state = { nodes = nodes },
  })

  local globals, shorts = 0, 0
  for key in pairs(snapshot) do
    if tostring(key):find(':', 1, true) then globals = globals + 1 else shorts = shorts + 1 end
  end
  assert_eq(globals, 8, 'alle acht Reaktoren muessen unter ihrer globalen Kennung vorliegen')
  assert_eq(shorts, 0, 'und kein kollidierender Alias darf uebrig bleiben')

  for index = 1, 8 do
    local entry = snapshot['rt-' .. index .. ':' .. short_ids[1]]
    assert_true(entry ~= nil, 'rt-' .. index .. ' muss im Relais stehen')
    assert_eq(entry.fuel_amount, 1000 + index * 100,
      'und zwar mit SEINEM Fuellstand, nicht dem eines anderen')
    assert_eq(entry.source_node, 'rt-' .. index, 'und seinem Knoten')
  end
end

print('ok fuel_multi_rt_identity_test')
