package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Aufzeichnung ist eine OPTIONALE Erweiterung (Manifest-Feature
-- "regler_trace") und fehlt auf jedem Knoten, der sie nicht mitinstalliert
-- hat. Das ist kein Randfall: dieser Anlage ging der Platz aus -- der
-- Installer meldete "benoetigt 727692 Bytes, verfuegbar 682337, es fehlen
-- 45355". Ein Diagnosewerkzeug als Pflichtgepaeck ist dann genau das
-- Falsche.
--
-- Pflicht: OHNE die Module muss der Regler normal arbeiten. Der erste
-- Anlauf hatte hier ein `return` im Fehlerzweig -- das haette init()
-- abgebrochen, noch VOR Kapazitaets-Cache, Anlagenprofil und dem Zustand
-- je Reaktor. Der Knoten waere ohne Regelung gestartet.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ── 1. Das Manifest fuehrt sie als optionales Feature ────────────────────

do
  local src = assert(io.open('xreactor/manifest.lua')):read('*a')
  for _, name in ipairs({ 'rt2_trace.lua', 'rt2_trace_writer.lua' }) do
    local line = src:match('[^\n]*nodes/rt/' .. name .. '[^\n]*')
    assert_true(line ~= nil, name .. ' fehlt im Manifest')
    assert_true(line:find('optional=true', 1, true) ~= nil,
      name .. ' muss optional sein -- sonst zaehlt sie auf jedem Knoten zum Pflichtumfang')
    assert_true(line:find('feature="regler_trace"', 1, true) ~= nil,
      name .. ' braucht den Feature-Namen, sonst fragt der Installer nie danach')
  end
end

-- ── 2. rt2_engine laedt sie NICHT beim Modulladen ────────────────────────
--
-- Ein require() am Dateikopf wuerde den ganzen Regler mitreissen, wenn die
-- Dateien nicht installiert sind.

do
  local src = assert(io.open('xreactor/nodes/rt/rt2_engine.lua')):read('*a')
  local head = src:sub(1, src:find('function M.init', 1, true) or #src)
  assert_true(head:find('require("nodes.rt.rt2_trace")', 1, true) == nil,
    'rt2_engine darf die Aufzeichnung nicht am Dateikopf laden')
  assert_true(head:find('require("nodes.rt.rt2_trace_writer")', 1, true) == nil,
    'dasselbe fuer den Writer')
  assert_true(src:find('pcall(require, "nodes.rt.rt2_trace")', 1, true) ~= nil,
    'geladen wird sie in init(), und abgesichert')
end

-- ── 3. Ohne die Module regelt der Knoten normal weiter ───────────────────
--
-- Der eigentliche Nachweis: init() muss vollstaendig durchlaufen und
-- tick() muss Entscheidungen liefern.

do
  -- Die Module aus dem Ladepfad nehmen, so wie auf einem Knoten ohne das
  -- Feature. package.preload mit einer Fehlerfunktion bildet genau das ab:
  -- require() schlaegt fehl, alles andere bleibt unberuehrt.
  -- Minimales fs: rt2_engine laedt beim Init Cache/Profil/Kennlinien.
  -- Es geht hier nicht um deren Inhalt, nur darum, dass init() diese
  -- Schritte ueberhaupt ERREICHT.
  _G.fs = _G.fs or {
    exists = function() return false end,
    open = function() return nil end,
    getDir = function(path) return path:match('^(.*)/[^/]+$') or '' end,
    makeDir = function() end,
    isDir = function() return false end,
    delete = function() end,
    getSize = function() return 0 end,
  }

  local missing = function() error('module not installed', 0) end
  package.preload['nodes.rt.rt2_trace'] = missing
  package.preload['nodes.rt.rt2_trace_writer'] = missing
  package.loaded['nodes.rt.rt2_trace'] = nil
  package.loaded['nodes.rt.rt2_trace_writer'] = nil

  local rt2_engine = require('nodes.rt.rt2_engine')

  local logged = {}
  rt2_engine.init({
    turbine_count = 2,
    config = { reactors = { 'R1' }, turbines = { 'T1', 'T2' }, trace = { enabled = true } },
    log = function(_, msg) logged[#logged + 1] = tostring(msg) end,
    cache_path = '/tmp/xr_trace_optional_cache.lua',
    tuning_path = '/tmp/xr_trace_optional_tuning.lua',
    turbine_model_path = '/tmp/xr_trace_optional_model.lua',
  })

  local said = false
  for _, msg in ipairs(logged) do
    if msg:find('Aufzeichnung nicht installiert', 1, true) then said = true end
  end
  assert_true(said, 'der Knoten muss sagen, dass die Aufzeichnung fehlt -- gesehen: '
    .. table.concat(logged, ' | '))

  -- Und jetzt der Punkt: er REGELT.
  local ctx = {
    config = { reactors = { 'R1' }, turbines = { 'T1', 'T2' } },
    CONFIG = { LOG_PREFIX = 'RT' },
    log = function() end,
    warn_once = function() end,
    modules = {},
    adapters = {
      turbine = {
        inspect = function(name)
          return { rpm = 500, flow = 100, energy = 1000, coil_engaged = false, active = true }
        end,
        set_flow = function() return true end,
        set_coils = function() return true end,
        set_active = function() return true end,
      },
      reactor = {
        inspect = function()
          return { steam_fill_ratio = 0.5, control_rod_level = 100, active = true,
                   temperature = 900, coolant_ratio = 1.0 }
        end,
        apply_rod_level = function() return true end,
        set_active = function() return true end,
      },
    },
  }

  local result = rt2_engine.tick(ctx)
  assert_true(type(result) == 'table', 'tick() liefert kein Ergebnis -- init() ist abgebrochen')
  assert_eq(#result.turbines, 2, 'beide Turbinen muessen eine Entscheidung bekommen')
  assert_true(result.reactors and #result.reactors == 1, 'der Reaktor muss geregelt werden')
  assert_true(result.state ~= nil, 'der Knoten muss einen Zustand haben')

  package.preload['nodes.rt.rt2_trace'] = nil
  package.preload['nodes.rt.rt2_trace_writer'] = nil
  package.loaded['nodes.rt.rt2_engine'] = nil
end

print('rt2_trace_optional_test.lua: ok')
