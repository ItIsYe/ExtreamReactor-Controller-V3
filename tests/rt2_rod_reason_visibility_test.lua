package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb (node-101, 2 Reaktoren, 50 Turbinen): beide Reaktoren
-- standen auf RODS 100%, DAMPF 0.0, der Knoten kam nie aus dem
-- Einlernen. Mit einem Reaktor und 25 Turbinen laeuft dieselbe Anlage.
--
-- 100% Einfahrung ist im Regler aber EIN Ergebnis mit mehreren voellig
-- verschiedenen Ursachen, und keine davon war irgendwo ablesbar. Die
-- Oberflaeche zeigt RODS/STEAM/STATE -- nicht, WARUM.
--
-- Besonders NO_STEAM_READING ist eine Sackgasse: ohne Dampfmesswert
-- faehrt der Reaktor sicherheitshalber voll ein, macht dadurch keinen
-- Dampf, und kommt aus eigener Kraft nie wieder heraus.

-- fs/textutils stand-ins for core.utils.load_config/write_config (used by
-- rt2_engine's capacity-cache persistence) -- same minimal fake as
-- registry_dirty_test.lua/rt_capacity_cache_persistence_regression_test.lua.
local files = { ['/xreactor_config'] = '<dir>' }
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function() return '/xreactor_config' end,
  makeDir = function(p) files[p] = '<dir>' end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  open = function(p, mode)
    if mode == 'w' then
      local buffer = ''
      return { write = function(v) buffer = buffer .. tostring(v) end, close = function() files[p] = buffer end }
    elseif mode == 'r' then
      if files[p] == nil or files[p] == '<dir>' then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.textutils = {
  serialize = function(value)
    local function encode(v)
      if type(v) == 'string' then return string.format('%q', v) end
      if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
      if type(v) ~= 'table' then return 'nil' end
      local parts = {}
      for k, item in pairs(v) do parts[#parts + 1] = '[' .. encode(k) .. ']=' .. encode(item) end
      table.sort(parts)
      return '{' .. table.concat(parts, ',') .. '}'
    end
    return encode(value)
  end,
  unserialize = function(content)
    local loader = load('return ' .. content, '=cache', 't', {})
    if not loader then return nil end
    local ok, value = pcall(loader)
    return ok and value or nil
  end,
}

-- Ohne Uhr steht now_ms auf 0 und der gestaffelte Suchlauf koennte nie
-- einschwingen -- er unterscheidet "faehrt noch hoch" von "kann diese
-- Stufe nicht halten" ueber die Zeit.
local clock_ms = 1000000
os.epoch = function() return clock_ms end
local function advance(ms) clock_ms = clock_ms + (ms or 1000) end

local engine = require('nodes.rt.rt2_engine')
local rt2_reactor = require('nodes.rt.rt2_reactor')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Ein Kontext mit zwei Reaktoren und einer Turbine, dessen Messwerte der
-- Test vorgibt.
local function make_ctx(readings)
  local printed = {}
  local ctx = {
    CONFIG = { LOG_PREFIX = 'RT' },
    config = { reactors = { 'R-A', 'R-B' }, turbines = { 'T1' }, safety = {} },
    log = function() end,
    adapters = {
      reactor = {
        inspect = function(name) return readings[name] end,
        apply_rod_level = function() return true end,
        set_active = function() return true end,
      },
      turbine = {
        inspect = function(name)
          return { name = name, rpm = 900, energy = 1000, coil_engaged = true, flow = 500, active = true }
        end,
        set_flow = function() return true end,
        set_coils = function() return true end,
        set_active = function() return true end,
      },
    },
  }
  return ctx, printed
end

local function run(ctx, printed, ticks)
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  for _ = 1, (ticks or 1) do pcall(engine.tick, ctx) end
  _G.print = real_print
end

-- ══ 1. Kein Dampfmesswert: die Sackgasse muss benannt werden ═══════════

do
  engine.init({ config = { reactors = { 'R-A', 'R-B' }, turbines = { 'T1' } },
    log = function() end })
  local readings = {
    -- R-A ohne Dampfmethoden (passiv gekuehlt / Anschluesse fehlen)
    ['R-A'] = { control_rod_level = 100, active = true, temperature = 90 },
    ['R-B'] = { control_rod_level = 100, active = true, temperature = 90,
                steam_fill_ratio = 0.5 },
  }
  local ctx, printed = make_ctx(readings)
  run(ctx, printed, 2)

  local said = table.concat(printed, ' | ')
  assert_true(said:find('R%-A') ~= nil,
    'der Reaktor ohne Dampfmesswert muss beim Namen genannt werden: ' .. said)
  assert_true(said:find('GAR KEIN Dampfmesswert', 1, true) ~= nil, said)
  assert_true(said:find('0 ist ein gueltiger Messwert', 1, true) ~= nil,
    'und die Meldung muss klarstellen, dass eine echte 0 etwas anderes ist: ' .. said)
  assert_true(said:find('faehrt dieser Reaktor nicht hoch', 1, true) ~= nil, said)
  -- Der gesunde Reaktor wird nicht mitgemeldet.
  assert_true(said:find('R%-B[^|]*GAR KEIN Dampfmesswert') == nil,
    'ein Reaktor mit Messwert darf nicht mitgemeldet werden: ' .. said)
end

-- ══ 2. Nur bei Aenderung, nicht in jedem Takt ══════════════════════════

do
  engine.init({ config = { reactors = { 'R-A', 'R-B' }, turbines = { 'T1' } },
    log = function() end })
  local readings = {
    ['R-A'] = { control_rod_level = 100, active = true, temperature = 90 },
    ['R-B'] = { control_rod_level = 100, active = true, temperature = 90, steam_fill_ratio = 0.5 },
  }
  local ctx, printed = make_ctx(readings)
  run(ctx, printed, 1)
  local first = #printed
  run(ctx, printed, 5)
  local later = 0
  for i = first + 1, #printed do
    if tostring(printed[i]):find('kein Dampfmesswert', 1, true) then later = later + 1 end
  end
  assert_true(later == 0, 'derselbe Grund darf den Schirm nicht fluten (' .. later .. ' Wiederholungen)')
end

-- ══ 3. Staebe am unteren Anschlag, Tank bleibt leer ════════════════════
--
-- Laut rt2_reactor.lua ausdruecklich KEIN Reglerfehler: die Anlage
-- fordert mehr Dampf, als die bewusst gesetzte 70%-Grenze hergibt. Bei 50
-- Turbinen an 2 Reaktoren ist das genau die Frage, die der Betreiber
-- beantwortet haben will -- und sie stand nirgends.

do
  engine.init({ config = { reactors = { 'R-A', 'R-B' }, turbines = { 'T1' } },
    log = function() end })
  local readings = {
    ['R-A'] = { control_rod_level = rt2_reactor.ROD_MIN, active = true, temperature = 90,
                steam_fill_ratio = 0.02 },
    ['R-B'] = { control_rod_level = rt2_reactor.ROD_MIN, active = true, temperature = 90,
                steam_fill_ratio = 0.02 },
  }
  local ctx, printed = make_ctx(readings)
  run(ctx, printed, 3)

  local said = table.concat(printed, ' | ')
  assert_true(said:find('unteren Anschlag', 1, true) ~= nil,
    'der Anschlag muss gemeldet werden: ' .. said)
  assert_true(said:find('Lastfrage', 1, true) ~= nil,
    'und als Lastfrage benannt, nicht als Reglerfehler: ' .. said)
end

-- ══ 4. Ein ABGELEHNTER Stabbefehl war voellig unsichtbar ══════════════
--
-- Der Betreiber hat die vorige Vermutung widerlegt: beide Reaktoren sind
-- aktiv gekuehlt und haben Dampfanschluesse. Ein Fuellstand von 0 ist
-- dann ein echter Messwert -- ein Geraet, das lange aus war, steht eben
-- auf 0. Der Regler MUSS daraufhin die Staebe ausfahren.
--
-- Tat er auch: rt2_adapter.apply_reactor() gibt sein Ergebnis samt
-- Fehlertext zurueck -- rt2_engine.tick() hat es weggeworfen. Scheitert
-- der Schreibbefehl dauerhaft, rechnet der Regler jeden Takt sauber eine
-- neue Stellung aus, die Hardware nimmt sie nie an, der Messwert bleibt
-- stehen, und der Knoten sagt kein Wort. Von aussen nicht zu
-- unterscheiden von "der Regler tut nichts".

do
  engine.init({ config = { reactors = { 'R-A', 'R-B' }, turbines = { 'T1' } },
    log = function() end })
  -- Leerer Tank: der Regler will die Staebe ausfahren ...
  local readings = {
    ['R-A'] = { control_rod_level = 100, active = true, temperature = 90, steam_fill_ratio = 0.0 },
    ['R-B'] = { control_rod_level = 100, active = true, temperature = 90, steam_fill_ratio = 0.0 },
  }
  local ctx, printed = make_ctx(readings)
  local wanted = {}
  -- ... die Hardware lehnt jeden Schreibbefehl ab.
  ctx.adapters.reactor.apply_rod_level = function(name, level)
    wanted[#wanted + 1] = { name = name, level = level }
    return nil, 'partial rod write 0/4: returned false'
  end
  run(ctx, printed, 3)

  assert_true(#wanted > 0, 'der Regler muss ueberhaupt etwas stellen wollen')
  local moved = false
  for _, w in ipairs(wanted) do if (w.level or 100) < 100 then moved = true end end
  assert_true(moved,
    'bei leerem Tank muss er die Staebe AUSFAHREN wollen -- sonst ist der Regler selbst schuld')

  local said = table.concat(printed, ' | ')
  assert_true(said:find('ABGELEHNT', 1, true) ~= nil,
    'und ein abgelehnter Stabbefehl darf nicht spurlos bleiben: ' .. said)
  assert_true(said:find('partial rod write', 1, true) ~= nil,
    'der Wortlaut der Hardware gehoert in die Meldung: ' .. said)
  assert_true(said:find('bleiben stehen', 1, true) ~= nil,
    'samt der Folge -- das ist der Unterschied zu "der Regler tut nichts": ' .. said)
end

-- ══ 5. Bei 50 Turbinen keine 50 Zeilen ════════════════════════════════

do
  engine.init({ config = { reactors = { 'R-A' }, turbines = { 'T1' } }, log = function() end })
  local readings = {
    ['R-A'] = { control_rod_level = 90, active = true, temperature = 90, steam_fill_ratio = 0.5 },
  }
  local ctx, printed = make_ctx(readings)
  ctx.config.reactors = { 'R-A' }
  ctx.config.turbines = {}
  for i = 1, 50 do ctx.config.turbines[i] = 'T' .. i end
  ctx.adapters.turbine.set_coils = function() return nil, 'no such method setCoilEngaged' end
  run(ctx, printed, 2)

  local lines = 0
  for _, line in ipairs(printed) do
    if tostring(line):find('nehmen keine Befehle an', 1, true) then lines = lines + 1 end
  end
  assert_true(lines == 1,
    'genau EINE gesammelte Zeile, nicht eine je Turbine (' .. lines .. ')')
  local said = table.concat(printed, ' | ')
  assert_true(said:find('no such method setCoilEngaged', 1, true) ~= nil,
    'mit dem Wortlaut der Hardware und einem Beispielgeraet: ' .. said)
  assert_true(said:find('50 Turbine', 1, true) ~= nil, 'und der Anzahl: ' .. said)
end

print('rt2_rod_reason_visibility_test.lua: ok')
