package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-15): "wenn sehr viel Cyanit da ist, dann soll die
-- Barrenanzahl erhoeht werden von 2 auf 4, 6, 8, 10 etc. und die Zeit bis
-- zum naechsten Push etwas verringert werden" -- Zahlen freigegeben
-- ("ja passt erstmal"): je 1000 Cyanit im ME eine Stufe, je Stufe +2
-- Barren (hoechstens 16) und 10 % kuerzere Pause (hoechstens 50 %).

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil
package.loaded['nodes.reprocessor.config_normalizer'] = nil

local fake_sorter = require('support.fake_mekanism_sorter')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_near(a, e, m)
  if math.abs(a - e) > 1e-9 then error((m or 'near') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local feed_router = require('nodes.reprocessor.feed_router')

-- ══ 1. Die freigegebene Tabelle ═════════════════════════════════════════

do
  local boost = feed_router.normalize_boost(nil)
  local rows = {
    -- Cyanit im ME, Barren, Faktor fuer die Pause
    { 0, 2, 1.0 }, { 999, 2, 1.0 },
    { 1000, 4, 0.9 }, { 1999, 4, 0.9 },
    { 2000, 6, 0.8 }, { 3000, 8, 0.7 }, { 4000, 10, 0.6 },
    { 5000, 12, 0.5 }, { 6000, 14, 0.5 }, { 7000, 16, 0.5 },
    { 50000, 16, 0.5 },
  }
  for _, r in ipairs(rows) do
    local level = feed_router.boost_level(r[1], boost)
    assert_eq(feed_router.boosted_amount(2, level, boost, r[1]), r[2], r[1] .. ' Cyanit: Barren')
    assert_near(feed_router.interval_factor(level, boost), r[3], r[1] .. ' Cyanit: Pause')
  end
end

-- ══ 2. Ausgeschaltet: alles wie vor v828 ════════════════════════════════

do
  local off = feed_router.normalize_boost({ enabled = false })
  local level = feed_router.boost_level(50000, off)
  assert_eq(level, 0)
  assert_eq(feed_router.boosted_amount(2, level, off, 50000), 2)
  assert_eq(feed_router.interval_factor(level, off), 1)
end

-- ══ 3. Grundmenge, Obergrenze, nie mehr als im ME ═══════════════════════

do
  local boost = feed_router.normalize_boost(nil)
  assert_eq(feed_router.boosted_amount(4, 1, boost, 1000), 6, 'eingestellte 4 + 2 je Stufe')
  assert_eq(feed_router.boosted_amount(20, 3, boost, 3000), 20, 'eine groessere Grundmenge wird nie gekappt')

  local fine = feed_router.normalize_boost({ stock_per_level = 1 })
  local level = feed_router.boost_level(7, fine)
  assert_eq(feed_router.boosted_amount(2, level, fine, 7), 6,
    'bei 7 im ME hoechstens 6 -- gerade und nicht mehr als vorhanden')
end

-- ══ 4. Einstellungen pruefen ═══════════════════════════════════════════

do
  local d = feed_router.BOOST_DEFAULTS
  local b = feed_router.normalize_boost(nil)
  assert_eq(b.enabled, true); assert_eq(b.stock_per_level, d.stock_per_level)
  assert_eq(b.max_amount, 16); assert_near(b.interval_cut_per_level, 0.10); assert_near(b.max_interval_cut, 0.50)

  local warnings = {}
  b = feed_router.normalize_boost({
    enabled = 'ja', stock_per_level = 0, max_amount = 15,
    interval_cut_per_level = 2, max_interval_cut = 0.95,
  }, function(m) warnings[#warnings + 1] = m end)
  assert_eq(b.enabled, true, 'kein Wahrheitswert: Vorgabe')
  assert_eq(b.stock_per_level, 1000, '0 je Stufe: Vorgabe')
  assert_eq(b.max_amount, 16, '15 wird gerade: 16')
  assert_near(b.interval_cut_per_level, 0.10, 'ueber 100 %: Vorgabe')
  assert_near(b.max_interval_cut, 0.50, 'ueber 90 %: Vorgabe -- eine Pause von null gibt es nicht')
  assert_eq(#warnings, 4, 'vier ungueltige Felder, vier Warnungen (15 ist nur ungerade, kein Fehler)')

  b = feed_router.normalize_boost({ stock_per_level = 500, max_amount = 32, interval_cut_per_level = 0.05, max_interval_cut = 0.3 })
  assert_eq(b.stock_per_level, 500); assert_eq(b.max_amount, 32)
  assert_near(b.interval_cut_per_level, 0.05); assert_near(b.max_interval_cut, 0.3)
end

-- ══ 5. Im Betrieb: Barren und Pause folgen dem ME-Bestand ═══════════════

local now_ms = 9000000
os.epoch = function() return now_ms end

local sorter = fake_sorter.new()
_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'sorter_chest_0' end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor', 'setAutoMode', 'setSingle' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, ...)
    if name == 'sorter_0' then return sorter.call(method, ...) end
    if name == 'sorter_chest_0' and method == 'list' then return {} end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local logistical_sorter = require('adapters.logistical_sorter')

local stock = 0
local asked = {}
local feed = feed_router.new({
  config = { feed = {
    enabled = true, waste_item = 'bigreactors:cyanite_ingot', feed_amount = 2,
    interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
    sorter_chest = 'sorter_chest_0',
    targets = { { label = 'Reprocessor A', color = 'RED' } },
  } },
  log = function() end, warn_once = function() end,
})
feed._state.bridge = {
  getItem = function() return { amount = stock } end,
  exportItemToPeripheral = function(filter) asked[#asked + 1] = filter.count; stock = stock - filter.count; return filter.count end,
}
feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
feed._state.sorter_name = 'sorter_0'

local function due_tick()
  feed._state.last_refresh = now_ms
  feed._state.next_feed_ts = now_ms - 1
  feed:tick()
  return (feed._state.next_feed_ts - now_ms) / 1000
end

do
  stock = 3500
  local pause = due_tick()
  assert_eq(asked[#asked], 8, '3500 Cyanit: Stufe 3, 8 Barren')
  assert_near(pause, 7, 'und 30 % kuerzere Pause: 7 s statt 10 s')
  local summary = feed:get_summary()
  assert_eq(summary.feed_amount, 8)
  assert_eq(summary.boost_level, 3)
  assert_eq(summary.me_stock, 3500)

  stock = 500
  pause = due_tick()
  assert_eq(asked[#asked], 2, 'unter 1000: wieder 2 Barren')
  assert_near(pause, 10, 'und die volle Pause')
  assert_eq(feed:get_summary().boost_level, 0)

  stock = 9000
  pause = due_tick()
  assert_eq(asked[#asked], 16, 'Obergrenze 16')
  assert_near(pause, 5, 'hoechstens halb so lange Pause')
end

-- ══ 6. Alte Config ohne boost-Block bekommt die Vorgaben ════════════════

do
  local utils = require('core.utils')
  local normalizer = require('nodes.reprocessor.config_normalizer')
  local defaults = {
    version = 1, role = 'REPROCESSOR-NODE', node_id = 'REPROC-1',
    debug_logging = false, reset_log_on_start = true,
    heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
    comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
      dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
    channels = { control = 6500, status = 6501 },
  }
  local cfg = utils.deep_copy(defaults)
  cfg.feed = { enabled = true, feed_amount = 2, sorter_chest = 'sorter_chest_0', sorter = 'sorter_0',
    targets = { { label = 'Reprocessor A', color = 'RED' } } }
  local warnings = {}
  normalizer.normalize(cfg, defaults, function(m) warnings[#warnings + 1] = m end, utils)
  assert_true(type(cfg.feed.boost) == 'table', 'boost-Block wird ergaenzt')
  assert_eq(cfg.feed.boost.stock_per_level, 1000)
  assert_eq(cfg.feed.boost.max_amount, 16)
  for _, w in ipairs(warnings) do
    assert_true(not tostring(w):find('boost', 1, true), 'ein fehlender Block ist kein Fehler: ' .. tostring(w))
  end
  assert_eq(cfg.feed.targets[1].label, 'Reprocessor A', 'Ziele bleiben')
end

print('reprocessor_feed_boost_test.lua: ok')
