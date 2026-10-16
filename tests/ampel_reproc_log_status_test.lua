package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-15): "es sollen alle Nodes eine Ampel bekommen, die
-- muss aber nicht zwingend installiert sein, weil Zusatzmodul". RT, ENERGY,
-- FUEL, MASTER (Gesamtampel) und VALVE (eingebauter Statusmonitor) hatten
-- schon eine; neu sind REPROC und LOG -- mit den freigegebenen Farbregeln.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a'); f:close(); return c
end

-- ══ 1. REPROC: Farbregeln ═══════════════════════════════════════════════

do
  package.loaded['nodes.reprocessor.feed_router'] = nil
  local fr = require('nodes.reprocessor.feed_router')
  local function ok_summary(over)
    local s = { enabled = true, bridge_bound = true, sorter_bound = true, sorter_chest_present = true,
      sorter_setup_ok = true, target_count = 2, last_error = nil, me_stock = 500, feed_amount = 2 }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local NIL = {}
  local function with(over)
    local s = ok_summary()
    for k, v in pairs(over) do if v == NIL then s[k] = nil else s[k] = v end end
    return s
  end
  local cases = {
    { 'laeuft normal',                   ok_summary(),                                        'OK' },
    { 'FEEDING aus',                     ok_summary({ enabled = false }),                    'muted' },
    { 'FEEDING aus schlaegt alles',      ok_summary({ enabled = false, bridge_bound = false }), 'muted' },
    { 'ME-Bridge fehlt',                 ok_summary({ bridge_bound = false }),               'EMERGENCY' },
    { 'Sorter fehlt',                    ok_summary({ sorter_bound = false }),               'EMERGENCY' },
    { 'Sorter-Kiste fehlt',              ok_summary({ sorter_chest_present = false }),      'EMERGENCY' },
    { 'Sorter-Einstellung gescheitert',  ok_summary({ sorter_setup_ok = false }),           'EMERGENCY' },
    { 'Farbe nicht angenommen',          ok_summary({ last_error = 'sorter_color_failed:color_not_applied' }), 'EMERGENCY' },
    { 'Einstellung noch nicht versucht', with({ sorter_setup_ok = NIL }),                    'OK' },
    { 'halbe Lieferung',                 ok_summary({ last_error = 'nur 1 von 2 bigreactors:cyanite_ingot exportiert (A)' }), 'WARNING' },
    { 'Export gescheitert',              ok_summary({ last_error = 'export failed' }),       'WARNING' },
    { 'kein Ziel',                       ok_summary({ target_count = 0 }),                   'WARNING' },
    { 'Sorter-Kiste belegt',             ok_summary({ last_error = 'Sorter-Kiste nicht leer (1x x) -- vorige Lieferung noch unterwegs, A wartet' }), 'LIMITED' },
    { 'zu wenig Cyanit',                 ok_summary({ me_stock = 1, feed_amount = 2 }),      'LIMITED' },
    { 'rot vor orange',                  ok_summary({ bridge_bound = false, target_count = 0 }), 'EMERGENCY' },
    { 'orange vor gelb',                 ok_summary({ target_count = 0, me_stock = 0 }),    'WARNING' },
  }
  for _, c in ipairs(cases) do
    assert_eq(fr.ampel_status(c[2]), c[3], 'REPROC: ' .. c[1])
  end
  assert_eq(fr.ampel_status(nil), 'muted', 'ohne Status: grau')
end

-- Die Kiste kommt in den Status, damit die Ampel sie sehen kann.
do
  _G.peripheral = { isPresent = function(name) return name == 'sorter_chest_0' end }
  package.loaded['nodes.reprocessor.feed_router'] = nil
  local fr = require('nodes.reprocessor.feed_router')
  local feed = fr.new({ config = { feed = { enabled = true, sorter_chest = 'sorter_chest_0' } } })
  assert_eq(feed:get_summary().sorter_chest_present, true)
  feed = fr.new({ config = { feed = { enabled = true, sorter_chest = 'weg' } } })
  assert_eq(feed:get_summary().sorter_chest_present, false)
  feed = fr.new({ config = { feed = { enabled = true } } })
  assert_eq(feed:get_summary().sorter_chest_present, false, 'keine Kiste gewaehlt')
end

-- REPROC zeichnet die Ampel in einem eigenen Takt -- nur, wenn das
-- Zusatzmodul da ist.
do
  local src = read('xreactor/nodes/reprocessor/main.lua')
  assert_true(src:find('pcall(require, "optional.ampel")', 1, true) ~= nil, 'REPROC laedt die Ampel optional')
  assert_true(src:find('name = "ampel_render"', 1, true) ~= nil, 'eigener Ampel-Takt')
  assert_true(src:find('router.ampel_status(router:get_summary())', 1, true) ~= nil, 'Farbe nach ampel_status')
end

-- ══ 2. LOG: Farbregeln ══════════════════════════════════════════════════

do
  local ampel_status = require('nodes.log_collector.ampel_status')
  local disk = { { mount = 'disk' } }
  local cases = {
    { 'laeuft',              { disks = disk, received = 10 },                          'OK' },
    { 'keine Disk',          { disks = {}, received = 10 },                            'EMERGENCY' },
    { 'Schreibfehler',       { disks = disk, received = 10, last_error = 'write failed' }, 'WARNING' },
    { 'pausiert',            { disks = disk, received = 10, paused = true },          'LIMITED' },
    { 'noch nichts da',      { disks = disk, received = 0 },                          'muted' },
    { 'rot vor allem',       { disks = {}, received = 0, paused = true, last_error = 'x' }, 'EMERGENCY' },
    { 'orange vor gelb',     { disks = disk, received = 5, paused = true, last_error = 'x' }, 'WARNING' },
    { 'gelb vor grau',       { disks = disk, received = 0, paused = true },           'LIMITED' },
  }
  for _, c in ipairs(cases) do
    assert_eq(ampel_status.status(c[2]), c[3], 'LOG: ' .. c[1])
  end
  assert_eq(ampel_status.status(nil), 'EMERGENCY', 'ohne Status: keine Disk bekannt')

  local src = read('xreactor/nodes/log_collector/main.lua')
  assert_true(src:find('pcall(require, "optional.ampel")', 1, true) ~= nil, 'LOG laedt die Ampel optional')
  assert_true(src:find('\n        render_ampel()\n', 1, true) ~= nil, 'LOG zeichnet die Ampel im Takt')
end

-- ══ 3. LOG: eine Ampel wird nie zur Log-Anzeige ═════════════════════════

do
  local src = read('xreactor/nodes/log_collector/main.lua')
  local start_pos = assert(src:find('local function is_ampel_monitor(monitor)', 1, true))
  local end_pos = assert(src:find('-- ── Optionale Ampel', start_pos, true))
  local chunk = 'local MONITOR_CFG_FILE = "/cfg"\n'
    .. 'local function safe_read() return nil end\n'
    .. 'local function trim(s) return s end\n'
    .. src:sub(start_pos, end_pos - 1)
    .. '\nreturn { find_display = find_display }\n'
  local mod = assert(load(chunk, '=log_find_display_slice'))()

  local function mon(w1, h1)
    local m = { scale = 0.5 }
    function m.getTextScale() return m.scale end
    function m.setTextScale(s) m.scale = s end
    function m.getSize() if m.scale == 1 then return w1, h1 end return w1 * 2, h1 * 2 end
    return m
  end
  local mons = { a_ampel_1x1 = mon(7, 5), b_ampel_1x3 = mon(7, 19), c_main = mon(29, 19) }
  _G.peripheral = {
    getNames = function() return { 'a_ampel_1x1', 'b_ampel_1x3', 'c_main' } end,
    getType = function() return 'monitor' end,
    wrap = function(n) return mons[n] end,
  }
  local name = mod.find_display()
  assert_eq(name, 'c_main', 'die Ampeln werden uebersprungen, der grosse Monitor wird Anzeige')
  assert_eq(mons.a_ampel_1x1.scale, 0.5, 'die Skala einer sondierten Ampel kommt zurueck')

  mons = { a_ampel_1x1 = mon(7, 5) }
  _G.peripheral.getNames = function() return { 'a_ampel_1x1' } end
  assert_eq(mod.find_display(), 'term', 'nur eine Ampel da: Anzeige im Terminal, nicht auf der Ampel')
end

-- ══ 4. Zusatzmodul: nicht zwingend installiert ══════════════════════════

do
  local manifest = dofile('xreactor/manifest.lua')
  local entry
  local function scan(entries)
    for _, e in ipairs(entries or {}) do if e.path == 'optional/ampel.lua' then entry = e end end
  end
  scan(manifest.base_files)
  for _, entries in pairs(manifest.roles) do scan(entries) end
  assert_true(entry ~= nil, 'optional/ampel.lua im Manifest')
  assert_eq(entry.optional, true, 'die Ampel bleibt ein Zusatzmodul')
  local roles = {}
  for _, r in ipairs(entry.required_for) do roles[r] = true end
  for _, r in ipairs({ 'RT', 'ENERGY', 'FUEL', 'REPROCESSING', 'LOG' }) do
    assert_true(roles[r], 'Ampel waehlbar fuer ' .. r)
  end
  local mm = require('installer.manifest')
  assert_eq(mm.files_for_role(manifest, 'LOG', {})['optional/ampel.lua'], nil, 'ohne Auswahl nicht installiert')
  assert_true(mm.files_for_role(manifest, 'LOG', { ampel = true })['optional/ampel.lua'] ~= nil, 'mit Auswahl installiert')
  assert_true(mm.files_for_role(manifest, 'LOG', {})['nodes/log_collector/ampel_status.lua'] ~= nil,
    'die kleine Farbregel des LOG kommt immer mit (ohne Ampel-Modul bleibt sie ungenutzt)')
end

print('ampel_reproc_log_status_test.lua: ok')
