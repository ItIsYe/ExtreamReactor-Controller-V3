package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb gemeldet: Logistik AN, Uran im ME, alle Reaktoren
-- konfiguriert -- und trotzdem wurde nichts losgeschickt, kein Ventil
-- gestellt, waehrend der Status "verbunden/wird beliefert" zeigte.
--
-- _run_supply() hatte fuenf Ausstiege. Zwei davon waren VOELLIG still
-- (keine ME-Bridge, Lieferung laeuft noch), der Rest ging ueber
-- warn_once()/DEBUG in den Log-Collector -- also nie auf den Schirm des
-- Rechners, und warn_once() ausserdem nur ein einziges Mal ueberhaupt.
--
-- Diese Datei haelt fest, dass jeder dieser Faelle einen ablesbaren Grund
-- hinterlaesst, und dass ein stillgelegter Eintrag uebersprungen wird,
-- ohne die uebrigen mitzunehmen.

local router_lib = require('nodes.fuel.logistics_router')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function new_router(logistics)
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local r = router_lib.new({
    config = { logistics = logistics },
    log = function() end,
    warn_once = function() end,
  })
  _G.print = real_print
  return r, printed
end

local function supply(router)
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local exported, errors = router:_run_supply({})
  _G.print = real_print
  return exported, errors, printed
end

-- ══ 1. Ohne ME-Bridge: frueher voellig still ════════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = nil
  local exported, _, printed = supply(router)
  assert_eq(exported, 0)
  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'ohne ME-Bridge muss ein Grund hinterlegt sein')
  assert_eq(block.code, 'KEINE_ME_BRIDGE')
  assert_true(#printed > 0,
    'und er muss am Rechner selbst stehen -- utils.log() routet zum Log-Collector,'
      .. ' nicht auf den Bildschirm')
  assert_true(tostring(printed[1]):find('FUEL', 1, true) ~= nil)
end

-- ══ 2. Ohne Uebergabepunkt ══════════════════════════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = nil
  supply(router)
  assert_eq(router:get_summary().supply_block.code, 'KEIN_UEBERGABEPUNKT')
end

-- ══ 3. Niemand fordert an -- auch das ist ein Grund ═════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {}
  supply(router)
  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'auch "nichts zu tun" muss ablesbar sein')
  assert_eq(block.code, 'NIEMAND_FORDERT_AN')
end

-- ══ 4. Der Grund wird nur bei AENDERUNG gemeldet ════════════════════════
--
-- Sonst ist der Bildschirm nach einer Minute zugemuellt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = nil
  local _, _, first = supply(router)
  local _, _, second = supply(router)
  assert_true(#first > 0, 'der erste Zyklus meldet')
  assert_eq(#second, 0, 'der zweite mit demselben Grund schweigt')
end

-- ══ 5. Ein stillgelegter Eintrag nimmt die uebrigen nicht mit ═══════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {
    { label = 'A', disabled_reason = 'ohne reactor_id', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
    { label = 'B', reactor_id = 'node-1:REACTOR-bbbb', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  supply(router)

  local summary = router:get_summary()
  local by_label = {}
  for _, entry in ipairs(summary.reactors) do by_label[entry.label] = entry end

  assert_true(by_label.A.disabled_reason ~= nil,
    'der stillgelegte Eintrag muss seinen Grund im Status tragen')
  assert_true(by_label.B.disabled_reason == nil,
    'der gute Eintrag bleibt unangetastet')

  -- Ein Eintrag OHNE reactor_id wuerde sonst in den Always-Supply-Modus
  -- fallen und ohne bekannten Fuellstand beliefert -- genau das darf die
  -- Stilllegung verhindern.
  assert_true(summary.supply_block == nil or summary.supply_block.code ~= 'ALWAYS_SUPPLY',
    'ein stillgelegter Eintrag darf nie in Always-Supply laufen')
end

-- ══ 6. "verbunden" heisst nicht "wird beliefert" ════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {
    { label = 'B', reactor_id = 'node-1:REACTOR-bbbb', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  local entry = router:get_summary().reactors[1]
  assert_eq(entry.identity_known, true,
    'die Kennung ist bekannt -- das ist alles, was das alte Feld je aussagte')
  assert_eq(entry.supplied, false,
    'aber geliefert wurde nie etwas, und genau das muss getrennt ablesbar sein')
  assert_eq(entry.last_export_ts, nil)
end

print('fuel_supply_block_reason_test.lua: ok')
