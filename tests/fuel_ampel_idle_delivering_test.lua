package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-15): "an [die] FUEL-Ampel muessen wir dran". Bis v830
-- lief jeder Lieferstopp-Grund aus logistics_router._run_supply() ueber
-- "Keine Lieferung" (WARNING) -- auch die normalen: kein Reaktor braucht
-- Brennstoff (NIEMAND_FORDERT_AN) und eine laufende Lieferung
-- (LIEFERUNG_LAEUFT, ROUTER_BESCHAEFTIGT). Die FUEL-Ampel war im
-- Normalbetrieb dadurch fast immer orange, gruen nur kurz nach einer
-- Lieferung, und "Lieferung aktiv" (gelb) kam praktisch nie zum Zug.
--
-- Jetzt: Leerlauf gruen, laufende Lieferung gelb, haengende Lieferung und
-- jeder echte Grund weiter orange -- und die echten Pruefungen (Lieferweg,
-- Reaktordaten, Reserve) gehen dem Leerlauf vor.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function deep_copy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

local HEALTHY = {
  reserve = 4000, minimum_reserve = 2000, master_connected = true,
  bindings = { storage = 1 }, routing_load_status = { ok = true },
  valve_summary = { total = 2, offline = 0, stale = 0 },
  logistics = {
    enabled = true, bridge = 'meBridge_0',
    reactors = {
      { label = 'R1', reactor_id = 'rt-1-reactor-0', fuel_pct = 80, fuel_data_state = 'FRESH', operational_state = 'READY' },
      { label = 'R2', reactor_id = 'rt-2-reactor-0', fuel_pct = 60, fuel_data_state = 'FRESH', operational_state = 'READY' },
    },
  },
}
local function payload(block, over)
  local p = deep_copy(HEALTHY)
  p.logistics.supply_block = block
  if over then over(p) end
  return p
end

-- ---- Ampel: echter Pfad monitor_ui.render_ampel -> optional/ampel ---------

local painted = {}
package.loaded['optional.ampel'] = {
  new = function() return { render = function(_, status) painted[#painted + 1] = status end } end,
}
package.loaded['nodes.fuel.monitor_ui'] = nil
package.loaded['nodes.fuel.ui_completion'] = nil
local monitor_ui = require('nodes.fuel.monitor_ui')
local completion = require('nodes.fuel.ui_completion')

local function view(p)
  return completion.compute_view_state({ payload = p }, {}, p.reserve, p.minimum_reserve)
end
local function ampel(p)
  local ctx = { build_status_payload = function() return p end, devices = { monitor_name = 'main' }, fuel_ui = {} }
  monitor_ui.render_ampel(ctx)
  return painted[#painted]
end

-- ══ 1. Leerlauf: gruen, mit Grund auf dem Schirm ════════════════════════

do
  local p = payload({ code = 'NIEMAND_FORDERT_AN', detail = '2 Eintraege geprueft: 2 ueber der Schwelle' })
  local v = view(p)
  assert_eq(v.code, 'IDLE', 'Leerlauf ist ein eigener, guter Zustand')
  assert_eq(v.severity, 'OK')
  assert_true(tostring(v.detail):find('ueber der Schwelle', 1, true) ~= nil, 'der Grund bleibt ablesbar')
  assert_eq(ampel(p), 'OK', 'die Ampel ist im Leerlauf gruen -- das war der Fehler')
end

-- ══ 2. Laufende Lieferung: gelb; haengende: orange ══════════════════════

do
  local p = payload({ code = 'LIEFERUNG_LAEUFT', detail = 'Reaktor 1 seit 4s in Phase HOLDING' })
  assert_eq(view(p).code, 'DELIVERING')
  assert_eq(ampel(p), 'LIMITED', 'laufende Lieferung ist gelb')

  p = payload({ code = 'ROUTER_BESCHAEFTIGT', detail = 'eine andere Transaktion laeuft noch' })
  assert_eq(ampel(p), 'LIMITED', 'Router beschaeftigt ist ebenfalls eine laufende Lieferung')

  p = payload({ code = 'LIEFERUNG_LAEUFT', detail = 'Reaktor 1 seit 95s', stuck = true })
  assert_eq(view(p).code, 'SUPPLY_BLOCKED', 'eine haengende Lieferung ist ein Missstand')
  assert_eq(ampel(p), 'WARNING')

  p = payload({ code = 'LIEFERUNG_LAEUFT', detail = 'x' }, function(q)
    q.logistics.current_request = { label = 'R2', reactor_id = 'rt-2-reactor-0' }
  end)
  assert_eq(view(p).detail, 'R2', 'mit laufender Anfrage nennt der Schirm den Reaktor')
end

-- ══ 3. Echte Gruende bleiben orange ═════════════════════════════════════

for _, code in ipairs({ 'KEIN_BRENNSTOFF_IM_ME', 'EXPORT_FEHLER', 'EXPORT_BEWEGTE_NICHTS',
                        'KEINE_ME_BRIDGE', 'LIEFERUNG_VERWAIST', 'KEIN_UEBERGABEPUNKT',
                        'ROUTING_ROUTING_INVALID', 'ROUTER_GESPERRT', 'KEIN_KANDIDAT_BEDIENBAR' }) do
  local p = payload({ code = code, detail = 'x' })
  assert_eq(view(p).code, 'SUPPLY_BLOCKED', code)
  assert_eq(ampel(p), 'WARNING', code .. ' bleibt orange')
end

-- ══ 4. Echte Pruefungen gehen dem Leerlauf vor ══════════════════════════

do
  local idle = { code = 'NIEMAND_FORDERT_AN', detail = 'x' }
  assert_eq(view(payload(idle, function(p) p.reserve = 1000 end)).code, 'RESERVE_LOW',
    'Leerlauf mit zu wenig Uran ist nicht gruen')
  assert_eq(view(payload(idle, function(p) p.logistics.reactors[2].fuel_data_state = 'STALE' end)).code, 'DATA_STALE')
  assert_eq(view(payload(idle, function(p) p.logistics.reactors[1].operational_state = 'BLOCKED' end)).code,
    'LOGISTICS_BLOCKED')
  assert_eq(ampel(payload(idle, function(p) p.logistics.reactors[1].fuel_pct = 5 end)), 'EMERGENCY',
    'unter 10 % Brennstoff bleibt rot, auch im Leerlauf')
  assert_eq(ampel(payload(nil)), 'OK', 'ganz ohne Grund: bereit')
end

-- ══ 5. Der Router markiert eine haengende Lieferung ═════════════════════

do
  package.loaded['nodes.fuel.logistics_router'] = nil
  local router_lib = require('nodes.fuel.logistics_router')
  local function running_for(ms)
    local real_print = print
    _G.print = function() end
    local router = router_lib.new({ config = { logistics = { enabled = true, reactors = {} } },
      log = function() end, warn_once = function() end })
    router._state.bridge = { name = 'meBridge_0', wrapped = {} }
    router._state.export_chest = { name = 'chest_0', wrapped = {} }
    router._state.rs_router = {
      get_active_transaction = function() return { transaction_id = 'tx-1', phase = 'HOLDING' } end,
      valve_count = function() return 2 end,
      get_routing_state = function() return 'ROUTING_VALID' end,
    }
    router._state.current_request = { label = 'R1', phase = 'HOLDING', started_ts = os.epoch('utc') - ms }
    router:_run_supply({})
    _G.print = real_print
    return router:get_summary().supply_block
  end
  local fresh = running_for(5000)
  assert_eq(fresh.code, 'LIEFERUNG_LAEUFT')
  assert_true(fresh.stuck ~= true, 'nach 5 s haengt nichts')
  local stuck = running_for(60000)
  assert_eq(stuck.code, 'LIEFERUNG_LAEUFT')
  assert_eq(stuck.stuck, true, 'nach 60 s gilt die Lieferung als haengend')
end

print('fuel_ampel_idle_delivering_test.lua: ok')
