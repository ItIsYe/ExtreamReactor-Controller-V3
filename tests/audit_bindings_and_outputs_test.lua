package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zwei P1-Befunde aus dem ATM10-8.1-Audit, beide vorher mit eigenen
-- Gegenproben reproduziert:
--
-- P01  Ein fest konfigurierter REPROCESSOR-Sorter, der gerade fehlt, wurde
--      durch einen BELIEBIGEN anderen ersetzt -- ohne Meldung.
-- (W02, der Abgleich der Wasser-Ausgaenge beim Start, ist mit der
-- WATER-Node in v830 entfallen.)

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

-- ── P01: eine ausdrueckliche Bindung ist verbindlich ─────────────────────
--
-- Vorher startete die allgemeine Methodensuche auch dann, wenn ein
-- konkreter Name konfiguriert, aber gerade nicht verfuegbar war. Der
-- Sorter verstellt seine Default-Farbe und damit sein Routing -- auf einem
-- gemeinsamen Peripherie-Netz mit FUEL gehoert der naechste gefundene
-- Sorter oft einem ganz anderen Zweig der Anlage. Gegenprobe vorher:
-- konfiguriert "sorter_mine", vorhanden nur "sorter_fremd" -> gebunden
-- wurde "sorter_fremd", und zwar ohne jede Warnung.
do
  local devices = {}
  local SORTER_METHODS = { 'setDefaultColor', 'getDefaultColor', 'setAutoMode' }
  _G.peripheral = {
    getNames = function()
      local out = {}
      for n in pairs(devices) do out[#out + 1] = n end
      table.sort(out); return out
    end,
    isPresent = function(n) return devices[n] ~= nil end,
    getType = function(n) return devices[n] and 'logisticalSorter' or nil end,
    getMethods = function(n) return devices[n] and SORTER_METHODS or {} end,
    wrap = function(n)
      if not devices[n] then return nil end
      return setmetatable({}, { __index = function() return function() return true end end })
    end,
    call = function() return true end,
  }
  os.epoch = function() return 1000000 end
  local feed_router = require('nodes.reprocessor.feed_router')

  local function bind(configured, present)
    devices = {}
    for _, n in ipairs(present) do devices[n] = true end
    local warns = {}
    local r = feed_router.new({
      config = { feed = { sorter = configured } },
      log = function() end,
      warn_once = function(_, m) warns[#warns + 1] = m end,
    })
    r:refresh_peripherals()
    return r._state.sorter_name, warns, r._state.sorter
  end

  local name = bind('sorter_mine', { 'sorter_mine', 'sorter_fremd' })
  assert_eq(name, 'sorter_mine', 'der konfigurierte Sorter wird gebunden, wenn er da ist')

  local name2, warns2, adapter2 = bind('sorter_mine', { 'sorter_fremd' })
  assert_true(name2 ~= 'sorter_fremd',
    'ein fehlender GEBUNDENER Sorter darf nicht durch einen fremden ersetzt werden')
  assert_eq(adapter2, nil, 'und es darf gar kein Sorter gebunden sein')
  local said_so = false
  for _, w in ipairs(warns2) do if w:find('sorter_mine', 1, true) then said_so = true end end
  assert_true(said_so, 'das fehlende gebundene Geraet muss beim Namen genannt werden')

  local name3 = bind('sorter_mine', {})
  assert_eq(name3, nil, 'ohne jeden Sorter bleibt es ungebunden')

  -- Ohne Konfiguration darf die Methodensuche weiterhin entscheiden --
  -- das ist der bewusst ungebundene Fall.
  local name4 = bind(nil, { 'sorter_fremd' })
  assert_eq(name4, 'sorter_fremd', 'ohne konfigurierten Namen bleibt die automatische Suche erlaubt')
end

print('audit_bindings_and_outputs_test.lua: ok')
