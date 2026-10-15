package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb (2026-10-15): der Sorter schickte immer nur EIN Item aus
-- der Kiste, obwohl zwei drin lagen -- "Single Item" war an (Mekanism holt
-- dann alle 0,5 s genau ein Item). Betreiber: "der Sorter soll nur beim
-- Starten einmalig eingestellt werden, also Single Mode off etc."
--
-- Diese Datei haelt fest:
--   1. prepare_for_feeding() stellt Single Item aus und Auto an und
--      prueft beides zurueck,
--   2. der REPROC tut das genau EINMAL je Sorter, erst mit FEEDING an,
--      und fasst den Sorter danach nicht wieder an -- auch nicht, wenn
--      jemand im Spiel umstellt,
--   3. misslingt es, wird hoechstens einmal je Erkennungsintervall neu
--      versucht, bis es einmal klappt.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil

local fake_sorter = require('support.fake_mekanism_sorter')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local now_ms = 5000000
os.epoch = function() return now_ms end

local sorters = {}
_G.peripheral = {
  isPresent = function(name) return sorters[name] ~= nil or name == 'sorter_chest_0' end,
  getMethods = function(name)
    if sorters[name] then return { 'setDefaultColor', 'getDefaultColor', 'setAutoMode', 'setSingle' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, ...)
    if sorters[name] then return sorters[name].call(method, ...) end
    if name == 'sorter_chest_0' and method == 'list' then return {} end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local function setting_calls(fake)
  local n = 0
  for _, c in ipairs(fake.calls) do
    if c.method == 'setSingle' or c.method == 'setAutoMode' then n = n + 1 end
  end
  return n
end

local logistical_sorter = require('adapters.logistical_sorter')
local feed_router = require('nodes.reprocessor.feed_router')

-- ══ 1. Der Adapter stellt ein und prueft zurueck ════════════════════════

do
  sorters.s = fake_sorter.new({ single = true, auto = false })
  local adapter = logistical_sorter.detect('s', 'TEST')
  local ok, err = adapter.prepare_for_feeding()
  assert_eq(ok, true, tostring(err))
  assert_eq(sorters.s.single, false, 'Single Item aus')
  assert_eq(sorters.s.auto, true, 'Auto an')

  sorters.s = fake_sorter.new({ single = true, public = false })
  ok, err = logistical_sorter.detect('s', 'TEST').prepare_for_feeding()
  assert_eq(ok, false)
  assert_true(tostring(err):find('security', 1, true) ~= nil, 'der echte Sicherheitsgrund kommt durch: ' .. tostring(err))

  sorters.s = fake_sorter.new({ single = true, ignore_set = true })
  ok, err = logistical_sorter.detect('s', 'TEST').prepare_for_feeding()
  assert_eq(ok, false, 'ohne Wirkung ist es kein Erfolg')
  assert_true(tostring(err):find('settings_not_applied', 1, true) ~= nil, tostring(err))
  sorters.s = nil
end

-- ---- Feed-Router -----------------------------------------------------------

local function new_feed(enabled)
  local feed = feed_router.new({
    config = { feed = {
      enabled = enabled, waste_item = 'bigreactors:cyanite_ingot', feed_amount = 2,
      interval_min_s = 10, interval_max_s = 10, discovery_interval = 60,
      sorter_chest = 'sorter_chest_0',
      targets = { { label = 'Reprocessor A', color = 'RED' } },
    } },
    log = function() end,
    warn_once = function() end,
  })
  feed._state.bridge = {
    getItem = function() return { amount = 1000 } end,
    exportItemToPeripheral = function(filter) return filter.count end,
  }
  feed._state.last_refresh = now_ms
  return feed
end

-- Ein Tick ohne Peripherie-Neuerkennung (die ist hier nicht Thema; die
-- Bindung setzt der Test selbst ueber bind()).
local function t(feed)
  feed._state.last_refresh = now_ms
  feed:tick()
end

local function bind(feed, name)
  feed._state.sorter = logistical_sorter.detect(name, 'TEST')
  feed._state.sorter_name = name
end

-- ══ 2. FEEDING aus: der Sorter wird nicht angefasst ═════════════════════

do
  sorters.sorter_0 = fake_sorter.new({ single = true })
  local feed = new_feed(false)
  bind(feed, 'sorter_0')
  for _ = 1, 3 do now_ms = now_ms + 11000; t(feed) end
  assert_eq(setting_calls(sorters.sorter_0), 0, 'ohne FEEDING keine Einstellung')
  assert_eq(feed:get_summary().sorter_setup_ok, nil, 'und der Status sagt: noch nicht versucht')
end

-- ══ 3. FEEDING an: genau einmal, danach nie wieder ══════════════════════

do
  sorters.sorter_0 = fake_sorter.new({ single = true, auto = false })
  local feed = new_feed(true)
  bind(feed, 'sorter_0')

  t(feed) -- erster Tick: stellt den Sorter ein (und spannt den Feed-Timer)
  assert_eq(setting_calls(sorters.sorter_0), 2, 'setSingle + setAutoMode, je einmal')
  assert_eq(sorters.sorter_0.single, false)
  assert_eq(sorters.sorter_0.auto, true)
  assert_eq(feed:get_summary().sorter_setup_ok, true)

  -- Jemand stellt im Spiel wieder auf Single Item -- der REPROC laesst das
  -- (Betreiber: nur beim Start einmalig).
  sorters.sorter_0.single = true
  for _ = 1, 5 do now_ms = now_ms + 61000; t(feed) end
  assert_eq(setting_calls(sorters.sorter_0), 2, 'kein zweites Mal, auch ueber mehrere Erkennungsintervalle')
  assert_eq(sorters.sorter_0.single, true, 'die Einstellung im Spiel bleibt, wie sie ist')
  assert_true(feed:get_summary().total_feeds > 0, 'befuellt wird ganz normal')
end

-- ══ 4. Misslingt es: Wiederholung je Erkennungsintervall, bis es klappt ═

do
  sorters.sorter_0 = fake_sorter.new({ single = true, public = false })
  local feed = new_feed(true)
  bind(feed, 'sorter_0')

  t(feed)
  local summary = feed:get_summary()
  assert_eq(summary.sorter_setup_ok, false)
  assert_true(tostring(summary.sorter_setup_error):find('security', 1, true) ~= nil,
    'der Grund steht im Status: ' .. tostring(summary.sorter_setup_error))
  local after_first = setting_calls(sorters.sorter_0)
  assert_eq(after_first, 1, 'ein Versuch (setSingle scheitert an der Sicherheit)')

  now_ms = now_ms + 30000; t(feed)
  assert_eq(setting_calls(sorters.sorter_0), after_first,
    'innerhalb des Erkennungsintervalls kein neuer Versuch')

  sorters.sorter_0.public = true -- Betreiber stellt auf Oeffentlich
  now_ms = now_ms + 31000; t(feed)
  assert_eq(feed:get_summary().sorter_setup_ok, true, 'nach dem Intervall neuer Versuch -- und der klappt')
  assert_eq(sorters.sorter_0.single, false)
  assert_eq(feed:get_summary().sorter_setup_error, nil)

  local done = setting_calls(sorters.sorter_0)
  for _ = 1, 3 do now_ms = now_ms + 61000; t(feed) end
  assert_eq(setting_calls(sorters.sorter_0), done, 'einmal gelungen: Ruhe')
end

-- ══ 5. Ein anderer Sorter wird gebunden: der wird einmal eingestellt ════

do
  sorters.sorter_0 = fake_sorter.new({ single = true })
  sorters.sorter_1 = fake_sorter.new({ single = true })
  local feed = new_feed(true)
  bind(feed, 'sorter_0')
  t(feed)
  assert_eq(setting_calls(sorters.sorter_0), 2)

  bind(feed, 'sorter_1') -- im Router-UI umgestellt
  now_ms = now_ms + 1000; t(feed)
  assert_eq(setting_calls(sorters.sorter_1), 2, 'der neue Sorter wird einmal eingestellt')
  assert_eq(sorters.sorter_1.single, false)
  assert_eq(setting_calls(sorters.sorter_0), 2, 'der alte bleibt unberuehrt')
end

print('reprocessor_sorter_setup_once_test.lua: ok')
