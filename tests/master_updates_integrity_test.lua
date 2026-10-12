package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Das Ergebnis der Dateipruefung erscheint auf MASTERs Seite "Updates" --
-- ohne den Heartbeat anzufassen.
--
-- Weg: installer/auto_update.lua legt das Ergebnis von
-- core/install_integrity.lua's check() als _G.__xreactor_install_integrity
-- ab -> shared/build_info.lua fasst es zusammen -> es geht mit jedem
-- STATUS-Paket in payload.meta.build an MASTER (services/telemetry_service.lua)
-- -> master/ui_controller.lua reicht es an master/ui/updates.lua weiter.
--
--   1. build_info: Zusammenfassung aus dem globalen Ergebnis, nil ohne
--   2. der HEARTBEAT bleibt, wie er ist (Betreiberwunsch): state und
--      manifest_version, sonst nichts
--   3. das STATUS-Paket traegt die Zusammenfassung in meta.build
--   4. ui_controller reicht sie je Knoten an die Updates-Seite weiter
--   5. die Seite zeigt "OK" / "N ABW" / "-" / "?" und zaehlt Knoten mit
--      abweichenden Dateien als "braucht Aufmerksamkeit"; ein Ergebnis zu
--      einer anderen Fassung als der gemeldeten gilt als unbekannt
--   6. MASTERs eigene Pruefung steht in der Fusszeile

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local build_info = require('shared.build_info')

-- ══ 1. build_info ═════════════════════════════════════════════════════════
rawset(_G, '__xreactor_install_integrity', nil)
assert_eq(build_info.get().integrity, nil, 'vor der ersten Pruefung kein Ergebnis')

rawset(_G, '__xreactor_install_integrity', {
  ok = false, checked = 120, missing = { 'a.lua' }, changed = { 'b.lua', 'c.lua' },
  manifest_id = 'manifest-v815', manifest_version = 815, payload_digest = 'abcdef12',
})
local summary = build_info.get().integrity
assert_true(type(summary) == 'table', 'nach der Pruefung gibt es eine Zusammenfassung')
assert_eq(summary.ok, false, 'Ergebnis')
assert_eq(summary.bad, 3, 'fehlende + veraenderte Dateien')
assert_eq(summary.checked, 120, 'gepruefte Dateien')
assert_eq(summary.version, 815, 'gegen welche Fassung geprueft wurde')
assert_eq(summary.digest, 'abcdef12', 'Pruefsumme der Fassung')
assert_eq(summary.changed, nil, 'die Dateiliste selbst geht nicht ueber Funk')

-- ══ 2./3. Heartbeat unveraendert, STATUS traegt die Zusammenfassung ══════
do
  -- Eine installierte Fassung, damit der Heartbeat seine manifest_version
  -- mitnimmt (shared/build_info.lua liest /xreactor/release.lua).
  local real_fs = rawget(_G, 'fs')
  _G.fs = {
    exists = function(p) return p == '/xreactor/release.lua' end,
    open = function() return nil end,
  }
  local real_dofile = dofile
  _G.dofile = function(p)
    if p == '/xreactor/release.lua' then return { manifest_version = 815, manifest_id = 'manifest-v815' } end
    return real_dofile(p)
  end
  local sent = {}
  local comms_service = require('services.comms_service')
  local svc = setmetatable({
    config = {},
    comms = { send = function(target, kind, payload) sent[#sent + 1] = { kind = kind, payload = payload } end },
  }, { __index = comms_service })
  svc:send_heartbeat({ state = 'RUNNING' })
  local hb = sent[#sent].payload
  local keys = {}
  for k in pairs(hb) do keys[#keys + 1] = k end
  table.sort(keys)
  assert_eq(table.concat(keys, ','), 'manifest_version,state',
    'der Heartbeat bleibt, wie er ist -- keine Dateipruefung darin')

  local telemetry = require('services.telemetry_service')
  local published
  local t = telemetry.new({
    comms = { publish_status = function(_, payload) published = payload end, send_heartbeat = function() end,
      network = { role = 'RT', id = 'RT-1' } },
    enable_heartbeat = false,
    build_payload = function() return { state = 'RUNNING' } end,
  })
  t:tick()
  assert_true(published ~= nil, 'ein STATUS-Paket wurde gesendet')
  local integrity = published.meta and published.meta.build and published.meta.build.integrity
  assert_true(type(integrity) == 'table', 'das STATUS-Paket traegt die Dateipruefung in meta.build')
  assert_eq(integrity.bad, 3, 'mit der Zusammenfassung')
  _G.fs, _G.dofile = real_fs, real_dofile
end

-- ══ 4. ui_controller reicht sie weiter ════════════════════════════════════
do
  package.loaded['master.ui_controller'] = nil
  local ui_controller = require('master.ui_controller')
  local captured
  local controller = ui_controller.new({
    constants = {
      roles = { ENERGY_NODE = 'ENERGY_NODE', RT_NODE = 'RT_NODE', WATER_NODE = 'WATER_NODE', FUEL_NODE = 'FUEL_NODE', REPROCESSOR_NODE = 'REPROCESSOR_NODE' },
      status_levels = { OK = 'OK', WARNING = 'WARNING', EMERGENCY = 'EMERGENCY', LIMITED = 'LIMITED', OFFLINE = 'OFFLINE', MANUAL = 'MANUAL' },
      node_states = { OFF = 'OFF' },
    },
    health = { reasons_list = function() return {} end, summarize_bindings = function() return nil end },
    config = {},
    nodes = {
      F = { id = 'F', role = 'FUEL_NODE', status = 'OK', manifest_version = 815,
        meta = { build = { manifest_version = 815, integrity = { ok = false, bad = 2, version = 815 } } } },
      W = { id = 'W', role = 'WATER_NODE', status = 'OK', manifest_version = 815 },
    },
    alarms = {},
    comms = { get_diagnostics = function() return {} end },
    sequencer = { ramp_profile = {}, state = 'idle', queue = {}, active = nil },
    view_manager = { render = function(_, _, data) captured = data.updates; return {} end },
    trends = { is_dirty = function() return false end, clear_dirty = function() end },
    trend_cache = { energy = {}, energy_arrow = '-' },
    state = { last_draw = 0, power_target = 0, active_profile = 'BASELOAD', auto_profile = false,
      critical_blink_until = 0, monitor_cache = { list = {} } },
    calc = { get_power_target = function() return 0 end, get_active_profile = function() return 'BASELOAD' end,
      get_auto_profile = function() return false end },
  })
  controller.draw()
  assert_true(captured ~= nil, 'die Updates-Seite bekam ein Modell')
  local by_id = {}
  for _, n in ipairs(captured.nodes) do by_id[n.id] = n end
  assert_true(by_id.F and type(by_id.F.integrity) == 'table', 'Knoten F traegt seine Dateipruefung')
  assert_eq(by_id.F.integrity.bad, 2, 'unveraendert durchgereicht')
  assert_eq(by_id.W.integrity, nil, 'Knoten ohne Ergebnis: nichts')
end

-- ══ 5./6. Die Seite ═══════════════════════════════════════════════════════
do
  local updates = require('master.ui.updates')
  local fs_files = { ['/xreactor/release.lua'] = 'return { manifest_version = 815, release_id = "beta-v815" }\n' }
  local real_fs = rawget(_G, 'fs')
  _G.fs = {
    exists = function(p) return fs_files[p] ~= nil end,
    open = function(p) return { readAll = function() return fs_files[p] end, close = function() end } end,
  }
  local rows = {}
  local cursor_y = 0
  local mon = {
    getSize = function() return 80, 30 end,
    setCursorPos = function(_, y) cursor_y = y end,
    write = function(text) rows[cursor_y] = (rows[cursor_y] or '') .. text end,
    setTextColor = function() end, setBackgroundColor = function() end, clear = function() end,
    isColor = function() return true end,
  }
  local function row_for(id)
    for _, text in pairs(rows) do
      if text:find(id, 1, true) and text:find('v8', 1, true) then return text end
    end
  end
  rawset(_G, '__xreactor_install_integrity', { ok = true, checked = 150, missing = {}, changed = {}, manifest_version = 815 })
  updates.render(mon, { nodes = {
    { id = 'RT-OK', manifest_version = 815, integrity = { ok = true, bad = 0, version = 815 } },
    { id = 'RT-BAD', manifest_version = 815, integrity = { ok = false, bad = 3, version = 815 } },
    { id = 'RT-OLDLIST', manifest_version = 815, integrity = { ok = nil, version = 815 } },
    { id = 'RT-NEW', manifest_version = 815 },
    { id = 'RT-PREV', manifest_version = 815, integrity = { ok = false, bad = 9, version = 814 } },
  } })
  _G.fs = real_fs

  local function check(id, files, status)
    local row = row_for(id)
    assert_true(row ~= nil, 'Zeile fuer ' .. id)
    assert_true(row:find(files, 1, true) ~= nil, id .. ': Spalte DATEIEN soll "' .. files .. '" zeigen: ' .. row)
    assert_true(row:find(status, 1, true) ~= nil, id .. ': Status soll "' .. status .. '" sein: ' .. row)
  end
  check('RT-OK', 'OK', 'OK')
  check('RT-BAD', '3 ABW', 'DATEIEN')
  check('RT-OLDLIST', ' -', 'OK')
  check('RT-NEW', '?', 'OK')
  check('RT-PREV', '?', 'OK')
  assert_true(not row_for('RT-PREV'):find('9 ABW', 1, true), 'ein Ergebnis zu einer anderen Fassung gilt nicht')

  local all = ''
  for _, text in pairs(rows) do all = all .. '\n' .. text end
  assert_true(all:find('ATTN 1', 1, true) ~= nil, 'genau ein Knoten braucht Aufmerksamkeit (RT-BAD)')
  assert_true(all:find('MASTER DATEIEN OK', 1, true) ~= nil, 'MASTERs eigene Pruefung in der Fusszeile')

  -- Direkt: die Statuslogik.
  local label, key = updates.status_for({ manifest_version = 815, integrity = { ok = false, bad = 1, version = 815 } }, 815)
  assert_eq(label, 'DATEIEN', 'aktuelle Fassung mit abweichenden Dateien')
  assert_eq(key, 'WARNING', 'braucht Aufmerksamkeit')
  label = updates.status_for({ manifest_version = 814, integrity = { ok = false, bad = 1, version = 814 } }, 815)
  assert_eq(label, 'UPDATE', 'eine alte Fassung bleibt "UPDATE" -- das Update ersetzt die Dateien ohnehin')
end

rawset(_G, '__xreactor_install_integrity', nil)
print('ok master_updates_integrity_test')
