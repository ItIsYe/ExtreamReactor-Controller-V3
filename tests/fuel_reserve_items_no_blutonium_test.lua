package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb (ATM10 8.1): Blutonium lag im Access Port und wurde vom
-- Reaktor nicht genommen, die Lieferkette staute sich.
--
-- Ursache ist kein Rezept, sondern Extreme Reactors selbst: der Reaktor
-- haelt immer nur EINEN Brennstofftyp. Solange noch Yellorium (aus Uran)
-- drin ist, lehnt er Blutonium ab -- es bleibt im Access Port liegen und
-- belegt dort den Slot, danach passt auch kein Uran mehr hinein. FUEL hat
-- bis v824 bei jeder Lieferung die Sorte mit dem groesseren ME-Bestand
-- gewaehlt; weil der REPROC laufend Blutonium nachliefert, kippte das
-- irgendwann auf Blutonium.
--
-- Seit v825 ist Blutonium ganz aus FUEL heraus (der REPROC bleibt). Diese
-- Datei haelt fest:
--   1. die ausgelieferte Liste in nodes/fuel/main.lua kennt kein Blutonium,
--   2. alte, gespeicherte Configs werden beim Laden bereinigt,
--   3. FUEL liefert Uran, auch wenn viel mehr Blutonium im ME liegt.

local utils = require('core.utils')
local normalizer = require('nodes.fuel.config_normalizer')
local router_lib = require('nodes.fuel.logistics_router')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Die bis v824 ausgelieferte Liste -- so steht sie in gespeicherten Configs,
-- weil FUEL seine Config samt reserve_items zurueckschreibt.
local function v824_reserve_items()
  return {
    { item = 'bigreactors:blutonium_ingot', element = 'blutonium' },
    { item = 'bigreactors:blutonium_block', element = 'blutonium', unit_multiplier = 9 },
    { item = 'alltheores:uranium_ingot', element = 'uranium' },
    { item = 'alltheores:uranium_block', element = 'uranium', unit_multiplier = 9 },
  }
end

local function defaults(reserve_items)
  return {
    channels = { control = 6501, status = 6502 },
    reserve_items = reserve_items or {
      { item = 'alltheores:uranium_ingot', element = 'uranium' },
      { item = 'alltheores:uranium_block', element = 'uranium', unit_multiplier = 9 },
    },
    target = 2000, minimum_reserve = 2000,
  }
end

local function normalize(reserve_items, defs)
  local cfg = { reserve_items = reserve_items }
  local warnings = {}
  normalizer.normalize(cfg, defs or defaults(), function(m) warnings[#warnings + 1] = m end, utils)
  local blut_warnings = 0
  for _, w in ipairs(warnings) do
    if tostring(w):find('Blutonium', 1, true) then blut_warnings = blut_warnings + 1 end
  end
  return cfg.reserve_items, blut_warnings
end

local function items_of(list)
  local out = {}
  for i, entry in ipairs(list) do out[i] = entry.item end
  return table.concat(out, ',')
end

-- ══ 1. Die ausgelieferte Liste kennt kein Blutonium ═════════════════════

do
  local f = assert(io.open('./xreactor/nodes/fuel/main.lua', 'r'))
  local src = f:read('*a')
  f:close()
  local block = src:match('\n  reserve_items = (%b{})')
  assert_true(block ~= nil, 'reserve_items-Block in DEFAULT_CONFIG nicht gefunden')
  assert_true(block:lower():find('blutonium', 1, true) == nil,
    'DEFAULT_CONFIG.reserve_items darf kein Blutonium mehr enthalten: ' .. block)
  assert_true(block:find('alltheores:uranium_ingot', 1, true) ~= nil, 'Uranbarren muessen drinbleiben')
  assert_true(block:find('alltheores:uranium_block', 1, true) ~= nil, 'Uranbloecke muessen drinbleiben')
end

-- ══ 2. Gespeicherte v824-Config wird bereinigt ══════════════════════════

do
  local list, blut_warnings = normalize(v824_reserve_items())
  assert_eq(items_of(list), 'alltheores:uranium_ingot,alltheores:uranium_block',
    'nur die Uran-Eintraege bleiben, in ihrer Reihenfolge')
  assert_eq(list[2].unit_multiplier, 9, 'der Block-Multiplikator bleibt erhalten')
  assert_eq(blut_warnings, 1, 'genau eine Warnung, die das Herausfiltern erklaert')
end

-- Erkannt wird ueber element ODER Item-Namen, ohne Ruecksicht auf Gross-/
-- Kleinschreibung -- eine von Hand gepflegte Liste muss nicht exakt so
-- aussehen wie die ausgelieferte.

do
  local list = normalize({
    { item = 'xr:fuel_rod_thing', element = 'Blutonium' },
    { item = 'SomeMod:BLUTONIUM_Nugget' },
    { item = 'alltheores:uranium_ingot', element = 'uranium' },
  })
  assert_eq(items_of(list), 'alltheores:uranium_ingot')
end

-- ══ 3. Eine reine Blutonium-Liste faellt auf die ausgelieferte zurueck ══
--
-- Sonst haette FUEL nach dem Bereinigen gar keinen Brennstoff mehr.

do
  local list, blut_warnings = normalize({
    { item = 'bigreactors:blutonium_ingot', element = 'blutonium' },
  })
  assert_eq(items_of(list), 'alltheores:uranium_ingot,alltheores:uranium_block')
  assert_eq(blut_warnings, 1)
end

-- Auch der Rueckfall nimmt kein Blutonium mit, falls es in den Defaults
-- doch einmal wieder auftaucht.

do
  local list = normalize(
    { { item = 'bigreactors:blutonium_block', element = 'blutonium', unit_multiplier = 9 } },
    defaults(v824_reserve_items()))
  assert_eq(items_of(list), 'alltheores:uranium_ingot,alltheores:uranium_block')
end

-- ══ 4. Eine saubere Liste bleibt unangetastet ═══════════════════════════

do
  local list, blut_warnings = normalize({
    { item = 'alltheores:uranium_ingot', element = 'uranium' },
  })
  assert_eq(items_of(list), 'alltheores:uranium_ingot')
  assert_eq(blut_warnings, 0, 'ohne Blutonium keine Warnung')
end

-- Eine absichtlich leere Liste bleibt leer -- der Rueckfall greift nur,
-- wenn erst das Herausfiltern sie geleert hat.

do
  local list, blut_warnings = normalize({})
  assert_eq(#list, 0)
  assert_eq(blut_warnings, 0)
end

-- ══ 5. Viel mehr Blutonium als Uran im ME: geliefert wird Uran ══════════

do
  local reserve_items = normalize(v824_reserve_items())
  local router = router_lib.new({
    config = { logistics = { enabled = true, reactors = {} }, reserve_items = reserve_items },
    log = function() end,
    warn_once = function() end,
  })
  local stock = {
    ['bigreactors:blutonium_ingot'] = 5000,
    ['bigreactors:blutonium_block'] = 500,
    ['alltheores:uranium_ingot'] = 200,
    ['alltheores:uranium_block'] = 0,
  }
  local asked, exported = {}, {}
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(filter)
      asked[#asked + 1] = filter.name
      return { name = filter.name, amount = stock[filter.name] or 0 }
    end,
    exportItemToPeripheral = function(filter, _)
      exported[#exported + 1] = filter.name
      return filter.count or 0
    end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30, path = {} },
  }

  local real_print = print
  _G.print = function() end
  local ok, err = pcall(router._run_supply, router, {})
  _G.print = real_print
  assert_true(ok, tostring(err))

  assert_true(#exported > 0, 'es muss geliefert werden')
  for _, name in ipairs(exported) do
    assert_eq(name, 'alltheores:uranium_ingot', 'geliefert wird Uran, nie Blutonium')
  end
  for _, name in ipairs(asked) do
    assert_true(not name:find('blutonium', 1, true),
      'FUEL fragt den Blutonium-Bestand gar nicht mehr ab: ' .. name)
  end
end

print('fuel_reserve_items_no_blutonium_test OK')
