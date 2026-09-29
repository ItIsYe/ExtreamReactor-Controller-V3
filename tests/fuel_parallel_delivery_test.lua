package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Sammellieferung: mehrere Reaktoren in EINER Ventil-Transaktion.
--
-- Betreiberwunsch (2026-09-29): mehrere Bestellungen sollen gleichzeitig
-- losgeschickt werden und nur die Menge aufgeteilt werden -- die Sorter
-- koennen das, sie sind je Ziel gefiltert und mengenbegrenzt.
--
-- Vorher lieferte _run_supply() immer genau einen Reaktor je Zyklus, und die
-- Zuordnung "welches Item zu wem" entstand allein daraus, dass nur ein
-- Ventilweg offen war. Jetzt wird die Vereinigung mehrerer Wege geoeffnet und
-- je Reaktor seine eigene Menge exportiert; wer wie viel bekommt, entscheiden
-- ab da die Sorter.
--
-- Die drei Dinge, die dabei schiefgehen koennen und die dieser Test haelt:
--   1. Zweimal denselben ME-Bestand verteilen (jeder Kandidat rechnet gegen
--      den vollen Bestand, obwohl der vorige schon zugeteilt hat).
--   2. Das Ventilfenster nach dem KUERZESTEN Weg bemessen -- die Ladung fuer
--      den entfernten Reaktor stuende dann beim Zufallen noch im Rohr.
--   3. hop_timing aus einer Sammellieferung lernen lassen -- eine Ankunft
--      laesst sich dann keiner der Lieferungen mehr zuordnen.

local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: erwartet %s, bekommen %s",
      label, tostring(expected), tostring(actual)), 2)
  end
end

local NOW = 1000000

local function make_bridge(stock, exports)
  return {
    wrapped = {
      getItem = function(filter)
        return { amount = stock[filter and filter.name] or 0 }
      end,
      exportItemToPeripheral = function(filter, target)
        exports[#exports + 1] = {
          name = filter.name, count = filter.count, target = target
        }
        return filter.count
      end,
    },
  }
end

local function make_rs(started)
  return {
    get_routing_state = function() return "ROUTING_VALID" end,
    begin_transaction = function(_self, target_id, action_fn, valve_ms, opts)
      started[#started + 1] = {
        target_id = target_id, valve_ms = valve_ms,
        extra_targets = opts and opts.extra_targets or {},
      }
      -- Der echte Router ruft action_fn erst in der EXPORTING-Phase; fuer
      -- den Test reicht der sofortige Aufruf, die Reihenfolge davor ist
      -- Sache von redstone_router.lua's eigenen Tests.
      action_fn()
      return true, "started", "tx-1"
    end,
    get_active_transaction = function() return { phase = "BLOCKING" } end,
  }
end

local function make_router(opts)
  opts = opts or {}
  local router = logistics_router.new({
    config = {
      reserve_items = {
        { item = 'alltheores:uranium_ingot', element = 'uranium' },
      },
      logistics = {
        enabled = true,
        interval = 5,
        valve_open_ms = 2000,
        parallel_deliveries = opts.parallel or 4,
      },
    },
    log = function() end,
    warn_once = function() end,
    fuel_status = opts.fuel_status,
    hop_timing = opts.hop_timing,
  })
  router._state.bridge = opts.bridge
  router._state.export_chest = { name = 'uebergabe_0' }
  router._state.rs_router = opts.rs
  router._state.reactors = opts.reactors
  return router
end

-- Drei anfordernde Reaktoren, absteigend leer.
local function three_reactors()
  return {
    { label = 'Reaktor A', reactor_id = 'RT-1:a', path = { 'V1' },
      request_below = 0.5, fill_amount = 64, min_in_me = 32,
      resupply_cooldown_s = 30 },
    { label = 'Reaktor B', reactor_id = 'RT-1:b', path = { 'V1', 'V2' },
      request_below = 0.5, fill_amount = 32, min_in_me = 32,
      resupply_cooldown_s = 30 },
    { label = 'Reaktor C', reactor_id = 'RT-2:c', path = { 'V3' },
      request_below = 0.5, fill_amount = 16, min_in_me = 32,
      resupply_cooldown_s = 30 },
  }
end

local function fuel_status_for(reactors, pct)
  local cache = { master_relay = {}, direct_heard = {} }
  for _, r in ipairs(reactors) do
    cache.direct_heard[r.reactor_id] = {
      fuel_amount = 1000 * pct, fuel_capacity = 1000, ts = NOW,
    }
  end
  return cache
end

-- os.epoch faelschen, damit die Frischepruefung (MAX_FUEL_DATA_AGE_MS) greift.
local real_epoch = os.epoch
os.epoch = function() return NOW end

-- Der Router sagt Betriebsartwechsel per print() auf dem Schirm an. Im Test
-- ist das nur Rauschen zwischen den Ergebnissen der Suite.
local real_print = print
print = function() end

-- 1. Drei Reaktoren, eine Transaktion, drei Exporte mit je EIGENER Menge.
do
  local exports, started = {}, {}
  local reactors = three_reactors()
  local router = make_router({
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 1000 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = fuel_status_for(reactors, 0.1),
  })
  router:_run_supply({})

  assert_eq(#started, 1, "es darf nur EINE Ventil-Transaktion geben")
  assert_eq(started[1].target_id, 'RT-1:a', "fuehrendes Ziel ist der leerste Reaktor")
  assert_eq(#started[1].extra_targets, 2, "die beiden anderen fahren mit")
  assert_eq(started[1].extra_targets[1], 'RT-1:b', "zweites Ziel")
  assert_eq(started[1].extra_targets[2], 'RT-2:c', "drittes Ziel")

  assert_eq(#exports, 3, "je Reaktor ein eigener Export")
  assert_eq(exports[1].count, 64, "Reaktor A bekommt sein fill_amount")
  assert_eq(exports[2].count, 32, "Reaktor B bekommt sein fill_amount")
  assert_eq(exports[3].count, 16, "Reaktor C bekommt sein fill_amount")
  for _, e in ipairs(exports) do
    assert_eq(e.target, 'uebergabe_0', "alles geht in die eine Uebergabekiste")
  end
end

-- 2. Der Bestand wird mitgefuehrt. 100 Barren im ME, min_in_me=32: fuer die
--    Gruppe stehen 68 zur Verfuegung. A nimmt 64, fuer B bleiben 4 -- nicht
--    noch einmal 32, als haette A nichts genommen.
do
  local exports, started = {}, {}
  local reactors = three_reactors()
  local router = make_router({
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 100 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = fuel_status_for(reactors, 0.1),
  })
  router:_run_supply({})

  assert_eq(exports[1].count, 64, "A nimmt sein volles fill_amount")
  assert_eq(exports[2].count, 4, "B bekommt nur noch, was ueber min_in_me uebrig ist")
  assert_eq(#exports, 2, "fuer C ist nichts mehr da")
  local sum = exports[1].count + exports[2].count
  assert_eq(sum, 68, "zusammen nie mehr als Bestand minus Mindestreserve")
end

-- 3. Das Ventilfenster richtet sich nach dem LAENGSTEN Weg der Gruppe.
do
  local exports, started = {}, {}
  local reactors = three_reactors()
  local asked = {}
  local hop_timing = {
    compute_timeout_ms = function(_self, path, default)
      asked[#asked + 1] = path
      -- Reaktor B (zwei Hops) ist der weite Weg.
      return #path >= 2 and 9000 or 2000
    end,
    begin_delivery = function() error('darf bei einer Sammellieferung nicht lernen', 0) end,
    finish_delivery = function() end,
  }
  local router = make_router({
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 1000 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = fuel_status_for(reactors, 0.1),
    hop_timing = hop_timing,
  })
  router:_run_supply({})

  assert_eq(#asked, 3, "jeder Weg der Gruppe wird bemessen")
  assert_eq(started[1].valve_ms, 9000,
    "das Fenster muss dem laengsten Weg folgen, sonst steht die letzte Ladung im Rohr")
end

-- 4. Bei genau EINER Lieferung lernt hop_timing weiterhin.
do
  local exports, started = {}, {}
  local reactors = { three_reactors()[1] }
  local learned = {}
  local hop_timing = {
    compute_timeout_ms = function(_self, _path, default) return default end,
    begin_delivery = function(_self, reactor_id) learned[#learned + 1] = reactor_id end,
    finish_delivery = function() end,
  }
  local router = make_router({
    parallel = 4,
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 1000 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = fuel_status_for(reactors, 0.1),
    hop_timing = hop_timing,
  })
  router:_run_supply({})

  assert_eq(#started, 1, "eine Transaktion")
  assert_eq(#started[1].extra_targets, 0, "ohne Mitfahrer")
  assert_eq(#learned, 1, "eine Einzellieferung darf weiterhin gelernt werden")
end

-- 5. parallel_deliveries = 1 ist das alte Verhalten: ein Reaktor je Zyklus.
do
  local exports, started = {}, {}
  local reactors = three_reactors()
  local router = make_router({
    parallel = 1,
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 1000 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = fuel_status_for(reactors, 0.1),
  })
  router:_run_supply({})

  assert_eq(#started, 1, "eine Transaktion")
  assert_eq(#started[1].extra_targets, 0, "keine Mitfahrer bei parallel_deliveries=1")
  assert_eq(#exports, 1, "genau ein Export")
end

-- 6. Reaktoren ueber ihrer Schwelle fahren nicht mit.
do
  local exports, started = {}, {}
  local reactors = three_reactors()
  local cache = fuel_status_for(reactors, 0.1)
  -- Reaktor B ist voll.
  cache.direct_heard['RT-1:b'].fuel_amount = 900
  local router = make_router({
    bridge = make_bridge({ ['alltheores:uranium_ingot'] = 1000 }, exports),
    rs = make_rs(started),
    reactors = reactors,
    fuel_status = cache,
  })
  router:_run_supply({})

  assert_eq(#started[1].extra_targets, 1, "nur der eine andere fordert an")
  assert_eq(started[1].extra_targets[1], 'RT-2:c', "und zwar C, nicht der volle B")
  assert_eq(#exports, 2, "zwei Exporte")
end

os.epoch = real_epoch
print = real_print
print("OK fuel_parallel_delivery_test")
