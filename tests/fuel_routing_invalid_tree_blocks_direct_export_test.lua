package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer FUEL/REPROCESSOR-P0.9 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 9 "Ungueltiges Routing kann
-- weiterhin direkten Export ausloesen"). Vor diesem Fix entschied
-- logistics_router.lua ueber "rs:route_count() > 0" (ein struktureller
-- Baum-Walk, unabhaengig vom echten Validierungszustand), ob Routing aktiv
-- ist. Ein KONFIGURIERTER, aber ungueltiger Baum, dessen struktureller
-- Walk zufaellig ebenfalls 0 Routen findet (z.B. ein "dead_end"-Knoten ohne
-- Reaktor-Ziel), wurde dadurch identisch zu "nie konfiguriert" behandelt --
-- FUEL fiel in den ungeschuetzten Direkt-Export-Pfad, OBWOHL redstone_
-- router.lua's eigene refresh() den Baum bereits als ungueltig erkannt und
-- block_all() ausgefuehrt hatte. Dieser Test beweist mit dem ECHTEN
-- redstone_router.lua: get_routing_state() erkennt diesen Fall korrekt als
-- ROUTING_INVALID, und logistics_router.lua exportiert dann UEBERHAUPT
-- NICHT (kein Routing-Versuch, aber auch kein Direktexport-Fallback).

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local redstone_router_lib = require('nodes.fuel.redstone_router')
local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_logistics(rs_router, export_result_fn)
  local exported_calls = {}
  local router = logistics_router.new({
    config = {
      logistics = { enabled = true },
      -- Einzelne Fuel-Familie, damit die Auto-Auswahl (build_fuel_families()/
      -- pick_fuel_family()) unveraendert 'bigreactors:yellorium_ingot' liefert.
      reserve_items = { { item = 'bigreactors:yellorium_ingot', element = 'yellorium' } },
    },
  })
  router._state.bridge = {
    name = 'me_bridge',
    wrapped = {
      getItem = function(_query) return { amount = 1000 } end,
      exportItemToPeripheral = function(query, inlet_name)
        table.insert(exported_calls, { query = query, inlet_name = inlet_name })
        return export_result_fn(query, inlet_name)
      end,
    },
  }
  router._state.reactors = {
    {
      label = 'Reactor A', reactor_id = nil,
      inlet = { name = 'transporter_1' },
      request_below = 0.25, fill_amount = 64, min_in_me = 32, cfg = {},
    },
  }
  router._state.rs_router = rs_router
  return router, exported_calls
end

-- 1. Ein KONFIGURIERTER aber strukturell kaputter Baum ("dead_end": ein
--    Ventil-Knoten ohne 'reactor' und ohne 'children') -- der alte
--    route_count()-Check haette hier faelschlich 0 zurueckgegeben (kein
--    Reaktor-Endpunkt im Walk auffindbar), identisch zu "nie konfiguriert".
do
  local rs = redstone_router_lib.new({
    config = { logistics = { redstone_tree = { { side = 'top' } } } },
    log = function() end, warn_once = function() end,
  })
  rs:refresh()

  assert_eq(rs._state.tree_configured, true, 'tree_configured should be true for a non-empty tree')
  assert_eq(rs._state.tree_valid, false, 'a dead-end node must be structurally invalid')
  assert_eq(rs:route_count(), 0, 'the naive structural walk finds no reactor endpoints here (the actual exploit condition)')
  assert_eq(rs:get_routing_state(), 'ROUTING_INVALID', 'get_routing_state must correctly classify this as ROUTING_INVALID, not ROUTING_NOT_CONFIGURED')

  local export_called = false
  local logistics, calls = make_logistics(rs, function() export_called = true; return 64 end)
  local result = logistics:run_cycle()

  assert_true(not export_called, 'FUEL must never fall through to an unguarded direct export when routing is configured-but-invalid')
  assert_eq(#calls, 0, 'exportItemToPeripheral must never be called')
  assert_eq(result.exported, 0, 'nothing should be reported as exported')
  assert_eq(logistics._state.total_exported, 0)
end

-- 2. Ein gueltiger, aber ventil-loser Baum (Routing ist erkennbar
--    beabsichtigt -- ein Reaktor-Ziel ist deklariert -- aber es existiert
--    kein einziges Ventil, das irgendetwas absichern koennte).
do
  local rs = redstone_router_lib.new({
    config = { logistics = { redstone_tree = { { reactor = 'R1', label = 'Reactor1' } } } },
    log = function() end, warn_once = function() end,
  })
  rs:refresh()

  assert_eq(rs._state.tree_valid, true, 'a bare reactor endpoint with no valves is structurally valid')
  assert_eq(#rs._state.all_valves, 0, 'no valve is declared anywhere in this tree')
  assert_eq(rs:get_routing_state(), 'ROUTING_REQUIRED_BUT_EMPTY', 'get_routing_state must flag a valid-but-valveless tree distinctly')

  local export_called = false
  local logistics = make_logistics(rs, function() export_called = true; return 64 end)
  logistics:run_cycle()

  assert_true(not export_called, 'ROUTING_REQUIRED_BUT_EMPTY must also block direct export')
end

-- 3. Regressionsschutz: ein wirklich NIE konfigurierter Baum (leer) muss
--    weiterhin den bisherigen, sicheren Direkt-Export-Pfad benutzen --
--    dieser Fix darf legitime ungeroutete Installationen nicht blockieren.
do
  local rs = redstone_router_lib.new({
    config = { logistics = { redstone_tree = {} } },
    log = function() end, warn_once = function() end,
  })
  rs:refresh()

  assert_eq(rs._state.tree_configured, false)
  assert_eq(rs:get_routing_state(), 'ROUTING_NOT_CONFIGURED')

  local export_called = false
  local logistics, calls = make_logistics(rs, function() export_called = true; return 64 end)
  local result = logistics:run_cycle()

  assert_true(export_called, 'a genuinely unconfigured (never-routed) installation must still export directly')
  assert_eq(#calls, 1)
  assert_eq(result.exported, 64)
end

print('fuel_routing_invalid_tree_blocks_direct_export_test.lua: ok')
