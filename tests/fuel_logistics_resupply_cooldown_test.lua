package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer resupply_cooldown_s (Feldbericht 2026-09-06: Fuel
-- staut sich in der letzten Kiste vor dem Reaktor an, weil logistics_
-- router.lua bisher jeden Belieferungszyklus (alle paar Sekunden) erneut
-- nachlegte, solange der vom Reaktor gemeldete Fuellstand (fuel_pct) noch
-- unter der Schwelle lag -- unabhaengig davon, ob die letzte Lieferung
-- physisch schon angekommen/verbraucht war. FUEL hat kein Wired-Modem-
-- Sichtfeld auf die letzte Kiste vor dem Reaktor, kann das also nicht
-- direkt pruefen; die Abklingzeit ist der pragmatische Ersatz dafuer.
--
-- Dieser Test treibt logistics_router.lua's echte run_cycle()/_run_supply()
-- (nach demselben Muster wie fuel_logistics_async_delivery_lifecycle_test.
-- lua) mit gemocktem os.epoch: (1) ein zweiter Zyklus kurz nach einer
-- erfolgreichen Lieferung darf NICHT erneut exportieren, obwohl fuel_pct
-- weiterhin unter der Schwelle liegt; (2) nach Ablauf von
-- resupply_cooldown_s darf wieder exportiert werden.

local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_fake_rs_router()
  local fake = { calls = {} }
  function fake:route_count() return 1 end
  function fake:get_routing_state() return 'ROUTING_VALID' end
  function fake:refresh() end
  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    table.insert(self.calls, { target_id = target_id })
    -- Synchron "vor Ort" ausfuehren, wie ein sofort abgeschlossener echter
    -- redstone_router.lua es am Ende tun wuerde -- fuer diesen Test reicht
    -- das, da nur record_export()'s Zeitstempel-Effekt geprueft wird, nicht
    -- die Ventil-Zustandsmaschine selbst (separat in ROUTER-P0 getestet).
    local ok, moved = action_fn()
    if opts and opts.on_complete then opts.on_complete({ state = 'COMPLETE_SAFE' }) end
    return true, 'started'
  end
  return fake
end

local now_ms = 1000000
local os_epoch = os.epoch
os.epoch = function(kind) if kind == 'utc' then return now_ms end return os_epoch(kind) end

local fuel_status = { master_relay = { ['rid-1'] = { fuel_amount = 100, fuel_capacity = 1000, ts = now_ms } }, direct_heard = {} }

local fake_rs = make_fake_rs_router()
local exported_calls = 0
local router = logistics_router.new({
  config = {
    logistics = { enabled = true, reactors = {}, valve_open_ms = 2000 },
    reserve_items = { { item = 'bigreactors:yellorium_ingot', element = 'yellorium' } },
  },
  fuel_status = fuel_status,
})
router._state.bridge = {
  name = 'me_bridge',
  wrapped = {
    getItem = function(_query) return { amount = 1000 } end,
    exportItemToPeripheral = function(_query, _inlet_name)
      exported_calls = exported_calls + 1
      return 64
    end,
  },
}
router._state.export_chest = { name = 'transporter_1' }
router._state.reactors = {
  {
    label = 'Reactor A', reactor_id = 'rid-1',
    request_below = 0.25, fill_amount = 64, min_in_me = 32,
    resupply_cooldown_s = 30, cfg = {},
  },
}
router._state.rs_router = fake_rs

-- 1. Erster Zyklus: fuel_pct=10% < 25% Schwelle -> exportiert einmal.
router:run_cycle()
assert_eq(exported_calls, 1, 'first cycle below threshold must export once')

-- 2. Zweiter Zyklus, nur 5s spaeter, fuel_pct weiterhin unveraendert unter
--    der Schwelle (Reaktor hat die Lieferung noch nicht verbraucht/RT hat
--    noch nicht neu gemeldet) -> Abklingzeit (30s) aktiv, KEIN erneuter Export.
now_ms = now_ms + 5000
fuel_status.master_relay['rid-1'].ts = now_ms  -- weiterhin frisch, sonst wuerde "keine frischen Daten" statt Cooldown greifen
router:run_cycle()
assert_eq(exported_calls, 1, 'a second cycle within resupply_cooldown_s must NOT export again (prevents pile-up)')

-- 3. Dritter Zyklus, nach Ablauf der Abklingzeit (weitere 26s, total 31s
--    seit der Lieferung) -> darf wieder exportieren.
now_ms = now_ms + 26000
fuel_status.master_relay['rid-1'].ts = now_ms
router:run_cycle()
assert_eq(exported_calls, 2, 'a cycle after resupply_cooldown_s has elapsed must export again')

os.epoch = os_epoch

print('fuel_logistics_resupply_cooldown_test.lua: ok')
