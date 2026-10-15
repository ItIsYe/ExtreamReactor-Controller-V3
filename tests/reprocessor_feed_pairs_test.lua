package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb (2026-10-15): der REPROC stellte am Sorter keine Farben
-- um, obwohl Ziele angelegt waren -- und der Reprocessor braucht immer 2
-- Cyanit auf einmal.
--
-- 1. Die Farbnamen der Router-UI sind die Namen aus dem Spiel; Mekanisms
--    setDefaultColor() nimmt aber nur seine Konstantennamen (DARK_BLUE,
--    nicht BLUE). Bis v825 gingen BLUE, GREEN, CYAN, LIGHT_GRAY,
--    LIGHT_BLUE, LIME, MAGENTA unuebersetzt raus und scheiterten, GRAY
--    setzte Hellgrau, PINK Magenta.
-- 2. Jeder Reprocessor bekommt seine Barren paarweise: feed_amount immer
--    gerade und >= 2, Farbwechsel erst bei leerer Sorter-Kiste, ein
--    Teil-Export wird mit derselben Farbe nachgeschoben.
-- 3. Gespeicherte Ziele (Namen, Farben, Sorter, Sorter-Kiste) bleiben beim
--    Laden unveraendert.

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.feed_router'] = nil
package.loaded['nodes.reprocessor.config_normalizer'] = nil

local fake_sorter = require('support.fake_mekanism_sorter')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ---- Welt ------------------------------------------------------------------

local world = {}
local function reset_world(opts)
  opts = opts or {}
  world.sorter = fake_sorter.new({ ignore_set = opts.ignore_set })
  world.chest = opts.chest or {}           -- Inhalt der Sorter-Kiste (list())
  world.chest_unreadable = opts.chest_unreadable == true
  world.me = opts.me or 1000               -- Cyanit im ME
  world.export_plan = opts.export_plan     -- Stueck je Exportaufruf, sonst alles
  world.exports = {}                       -- { count=, color= (Mekanism) }
end
reset_world()

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'sorter_chest_0' end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'clearDefaultColor', 'getDefaultColor' } end
    return {}
  end,
  getType = function() return 'logisticalSorter' end,
  call = function(name, method, ...)
    if name == 'sorter_0' then return world.sorter.call(method, ...) end
    if name == 'sorter_chest_0' and method == 'list' then
      if world.chest_unreadable then error('no list') end
      return world.chest
    end
    error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method))
  end,
}

local function bridge()
  return {
    getItem = function(_) return { amount = world.me } end,
    exportItemToPeripheral = function(filter, _target)
      local n = filter.count
      if world.export_plan then n = math.min(n, table.remove(world.export_plan, 1) or 0) end
      world.exports[#world.exports + 1] = { count = n, asked = filter.count, color = world.sorter.color }
      return n
    end,
  }
end

local logistical_sorter = require('adapters.logistical_sorter')
local feed_router = require('nodes.reprocessor.feed_router')

local function new_feed(targets, feed_amount)
  local warnings = {}
  local feed = feed_router.new({
    config = { feed = {
      enabled = true, waste_item = 'bigreactors:cyanite_ingot', feed_amount = feed_amount or 2,
      interval_min_s = 10, interval_max_s = 10, discovery_interval = 9999,
      sorter_chest = 'sorter_chest_0', targets = targets,
    } },
    log = function() end,
    warn_once = function(key, msg) warnings[key] = msg end,
  })
  feed._state.bridge = bridge()
  feed._state.sorter = logistical_sorter.detect('sorter_0', 'TEST')
  feed._state.last_refresh = os.epoch('utc')
  return feed, warnings
end

local function due_tick(feed)
  feed._state.next_feed_ts = os.epoch('utc') - 1
  feed:tick()
end

-- ══ 1. feed_amount: ganze, gerade Zahl, mindestens 2 ════════════════════

do
  local n = feed_router.normalize_feed_amount
  assert_eq(n(1), 2); assert_eq(n(2), 2); assert_eq(n(3), 4); assert_eq(n(2.5), 4)
  assert_eq(n(4), 4); assert_eq(n(63), 64); assert_eq(n(64), 64)
  assert_eq(n(0), 2); assert_eq(n(-5), 2); assert_eq(n(nil), 2); assert_eq(n('x'), 2)
  assert_eq(n(0 / 0), 2, 'NaN'); assert_eq(n(math.huge), 2, 'unendlich')
  assert_eq(n('6'), 6, 'eine Zahl als Text zaehlt wie die Zahl')
end

-- ══ 2. Farben kommen als Mekanisms Farben am Sorter an ══════════════════
--
-- Genau die Namen, die bis v825 scheiterten oder falsch ankamen.

do
  reset_world()
  local feed = new_feed({
    { label = 'Reprocessor A', color = 'BLUE' },
    { label = 'Reprocessor B', color = 'LIME' },
    { label = 'Reprocessor C', color = 'GRAY' },
    { label = 'Reprocessor D', color = 'PINK' },
  })
  for _ = 1, 4 do due_tick(feed) end
  assert_eq(#world.exports, 4, 'jedes Ziel wird beliefert: ' .. tostring(feed:get_summary().last_error))
  assert_eq(world.exports[1].color, 'DARK_BLUE')
  assert_eq(world.exports[2].color, 'BRIGHT_GREEN')
  assert_eq(world.exports[3].color, 'DARK_GRAY', 'GRAY ist im Spiel "Gray", nicht Hellgrau')
  assert_eq(world.exports[4].color, 'BRIGHT_PINK', 'PINK ist im Spiel "Pink", nicht Magenta')
  for i, e in ipairs(world.exports) do assert_eq(e.count, 2, 'Feed ' .. i .. ': immer 2 Barren') end
  assert_eq(feed:get_summary().total_feeds, 4)
  assert_eq(feed:get_summary().last_error, nil)
end

-- ══ 3. Sorter uebernimmt die Farbe nicht: kein Export ═══════════════════

do
  reset_world({ ignore_set = true })
  local feed = new_feed({ { label = 'Reprocessor A', color = 'RED' } })
  due_tick(feed)
  assert_eq(#world.exports, 0, 'ohne bestaetigte Farbe wird nichts exportiert')
  assert_true(tostring(feed:get_summary().last_error):find('color_not_applied', 1, true) ~= nil,
    'und der Grund steht im Status: ' .. tostring(feed:get_summary().last_error))
end

-- ══ 4. Sorter-Kiste nicht leer: Farbe bleibt, Ziel bleibt dran ══════════

do
  reset_world({ chest = { [1] = { name = 'bigreactors:cyanite_ingot', count = 1 } } })
  -- Drei Ziele: mit zwei Wartetakten landete eine weiterlaufende Rotation
  -- bei zwei Zielen zufaellig wieder bei A.
  local feed, warnings = new_feed({
    { label = 'Reprocessor A', color = 'RED' },
    { label = 'Reprocessor B', color = 'BLUE' },
    { label = 'Reprocessor C', color = 'LIME' },
  })
  world.sorter.color = 'YELLOW' -- Farbe der vorigen Lieferung
  due_tick(feed)
  assert_eq(#world.exports, 0, 'solange die Kiste belegt ist, wird nicht geliefert')
  assert_eq(world.sorter.color, 'YELLOW', 'und die Farbe der vorigen Lieferung bleibt stehen')
  assert_true(tostring(feed:get_summary().last_error):find('Sorter-Kiste nicht leer', 1, true) ~= nil,
    tostring(feed:get_summary().last_error))
  assert_true(warnings.sorter_chest_busy ~= nil)

  due_tick(feed) -- immer noch belegt
  assert_eq(#world.exports, 0)

  world.chest = {} -- der Sorter hat die Kiste geleert
  due_tick(feed)
  assert_eq(#world.exports, 1)
  assert_eq(world.exports[1].color, 'RED', 'das wartende Ziel A kommt zuerst dran, nicht ein spaeteres')
  assert_eq(feed:get_summary().last_error, nil, 'der Hinweis verschwindet mit der naechsten Lieferung')
  due_tick(feed)
  assert_eq(world.exports[2].color, 'DARK_BLUE', 'danach geht es normal weiter mit B')
end

-- Laesst sich die Kiste nicht auslesen, wird trotzdem geliefert (mit
-- einmaliger Warnung) -- eine fehlende Pruefung legt die Anlage nicht still.

do
  reset_world({ chest_unreadable = true })
  local feed, warnings = new_feed({ { label = 'Reprocessor A', color = 'RED' } })
  due_tick(feed)
  assert_eq(#world.exports, 1)
  assert_true(warnings.sorter_chest_unreadable ~= nil)
end

-- ══ 5. Teil-Export wird mit derselben Farbe nachgeschoben ═══════════════

do
  reset_world({ export_plan = { 1, 1 } })
  local feed = new_feed({ { label = 'Reprocessor A', color = 'CYAN' } })
  due_tick(feed)
  assert_eq(#world.exports, 2, 'erst 1, dann der Rest')
  assert_eq(world.exports[1].asked, 2)
  assert_eq(world.exports[2].asked, 1, 'nachgeschoben wird genau der fehlende Barren')
  assert_eq(world.exports[1].color, 'DARK_AQUA')
  assert_eq(world.exports[2].color, 'DARK_AQUA', 'mit derselben Farbe, also zum selben Reprocessor')
  assert_eq(feed:get_summary().total_feeds, 1)
  assert_eq(feed:get_summary().last_error, nil)
end

do
  reset_world({ export_plan = { 1, 0 } })
  local feed = new_feed({ { label = 'Reprocessor A', color = 'CYAN' } })
  due_tick(feed)
  local summary = feed:get_summary()
  assert_eq(summary.total_feeds, 0, 'eine halbe Lieferung zaehlt nicht als Lieferung')
  assert_true(tostring(summary.last_error):find('nur 1 von 2', 1, true) ~= nil, tostring(summary.last_error))
end

-- ══ 6. Eine ungerade/zu kleine Menge wird auch zur Laufzeit gerade ══════

do
  reset_world()
  local feed = new_feed({ { label = 'Reprocessor A', color = 'RED' } }, 3)
  due_tick(feed)
  assert_eq(world.exports[1].asked, 4, 'feed_amount 3 liefert 4')
  assert_eq(feed:get_summary().feed_amount, 4)

  reset_world()
  feed = new_feed({ { label = 'Reprocessor A', color = 'RED' } }, 1)
  due_tick(feed)
  assert_eq(world.exports[1].asked, 2, 'feed_amount 1 liefert 2')

  reset_world({ me = 3 })
  feed = new_feed({ { label = 'Reprocessor A', color = 'RED' } }, 4)
  due_tick(feed)
  assert_eq(#world.exports, 0, 'zu wenig im ME: lieber gar nicht als halb')
end

-- ══ 7. Laden: gespeicherte Ziele bleiben, nur feed_amount wird gerade ═══

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
    feed = { feed_amount = 2 },
  }
  local function load(feed_amount)
    local cfg = utils.deep_copy(defaults)
    cfg.feed = {
      enabled = true, me_bridge = 'me_bridge', sorter = 'logisticalSorter_3', sorter_chest = 'sorter_chest_0',
      waste_item = 'bigreactors:cyanite_ingot', feed_amount = feed_amount,
      interval_min_s = 20, interval_max_s = 60, discovery_interval = 60,
      active_colors = { 'BLUE', 'LIME', 'GRAY' },
      targets = {
        { label = 'Reprocessor Nord', color = 'BLUE' },
        { label = 'Reprocessor Sued', color = 'LIME' },
        { label = 'Reprocessor West', color = 'GRAY' },
        { label = 'Reprocessor Ost', color = 'PINK' },
      },
    }
    local warnings = {}
    normalizer.normalize(cfg, defaults, function(m) warnings[#warnings + 1] = m end, utils)
    return cfg.feed, warnings
  end

  local fd, warnings = load(2)
  assert_eq(fd.feed_amount, 2)
  for _, w in ipairs(warnings) do
    assert_true(not tostring(w):find('feed_amount', 1, true), 'bei 2 keine Warnung: ' .. tostring(w))
  end
  assert_eq(#fd.targets, 4, 'alle Ziele bleiben')
  local expect = { { 'Reprocessor Nord', 'BLUE' }, { 'Reprocessor Sued', 'LIME' },
                   { 'Reprocessor West', 'GRAY' }, { 'Reprocessor Ost', 'PINK' } }
  for i, e in ipairs(expect) do
    assert_eq(fd.targets[i].label, e[1], 'Name bleibt')
    assert_eq(fd.targets[i].color, e[2], 'Farbname bleibt, wie er gespeichert ist')
  end
  assert_eq(fd.sorter, 'logisticalSorter_3', 'Sorter-Bindung bleibt')
  assert_eq(fd.sorter_chest, 'sorter_chest_0', 'Sorter-Kiste bleibt')
  assert_eq(fd.enabled, true, 'FEEDING bleibt eingeschaltet')
  assert_eq(#fd.active_colors, 3, 'die Farbauswahl der FARBEN-Seite bleibt')

  local fd1, w1 = load(1)
  assert_eq(fd1.feed_amount, 2, '1 wird 2')
  local warned = false
  for _, w in ipairs(w1) do if tostring(w):find('feed_amount 1 -> 2', 1, true) then warned = true end end
  assert_true(warned, 'und das wird gemeldet')

  assert_eq((load(5)).feed_amount, 6, '5 wird 6')
  assert_eq((load(nil)).feed_amount, 2, 'fehlend: Vorgabe 2')
end

print('reprocessor_feed_pairs_test.lua: ok')
