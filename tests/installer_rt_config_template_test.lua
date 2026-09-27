package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der Installer legt /xreactor_config/rt.lua an. utils.load_config()
-- SCHREIBT eine fehlende Datei nicht -- es liefert nur die Vorgaben zurueck,
-- ein frischer Knoten stand also ohne diese Datei da.
--
-- Bis v768 trug die Vorlage ein Feld engine, das zwischen zwei Reglern
-- waehlte; seine Vorgabe war der alte. Beides ist entfallen -- es gibt nur
-- noch einen Regler. Die Vorlage ist damit leer bis auf ihre Kommentare,
-- und genau das soll sie sein: der Knoten fuellt sie beim ersten Start
-- aus seinen Vorgaben auf.
--
-- Diese Datei prueft die tatsaechlich ausgelieferte Vorlage -- nicht eine
-- Nachbildung davon -- und vor allem die Eigenschaften, an denen es
-- wehtun wuerde:
--   * eine VORHANDENE Datei wird nie ueberschrieben (sonst waere nach
--     jedem Update die ganze Knoten-Config weg),
--   * nur die Rolle RT bekommt sie,
--   * sie ist gueltiges Lua und liefert eine Tabelle,
--   * der Pfad ist der, den die Node wirklich liest.

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function read(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read('*a'); f:close(); return s
end

local src = read('xreactor/installer/init.lua')

-- ══ 1. Nur fuer RT, und nur wenn es die Datei noch nicht gibt ════════════

do
  local at = src:find('local rt_cfg = CONFIG_DIR .. "/rt.lua"', 1, true)
  assert_true(at ~= nil, 'der Installer muss /xreactor_config/rt.lua anlegen')

  local role_gate = src:find('if role.label == "RT" then', 1, true)
  assert_true(role_gate ~= nil and role_gate < at,
    'nur die Rolle RT bekommt die Datei -- andere Rollen lesen sie nie')

  local guard = src:find('if not fs.exists(rt_cfg) then', at, true)
  local write_at = src:find('stage_mod.write(rt_cfg', at, true)
  assert_true(guard ~= nil and write_at ~= nil and guard < write_at,
    'eine VORHANDENE rt.lua darf nie ueberschrieben werden -- sonst ist nach'
      .. ' jedem Update die Engine-Wahl und die ganze Knoten-Config weg')
end

-- ══ 2. Die ausgelieferte Vorlage ist gueltiges Lua ══════════════════════
--
-- Den Textblock aus dem Installer holen und genauso zusammensetzen, wie
-- er auf die Platte geht. Eine kaputte Vorlage wuerde den Knoten beim
-- naechsten Start ohne Config dastehen lassen.

local template
do
  local open_at = src:find('stage_mod.write(rt_cfg, table.concat({', 1, true)
  assert_true(open_at ~= nil, 'Vorlagenblock nicht gefunden')
  local body_at = open_at + #'stage_mod.write(rt_cfg, table.concat({'
  local close_at = src:find('\n    }))', body_at, true)
  assert_true(close_at ~= nil, 'Ende des Vorlagenblocks nicht gefunden')

  local chunk = 'return table.concat({' .. src:sub(body_at, close_at) .. '})'
  local loader, err = load(chunk, '=template', 't', { table = table })
  assert_true(loader ~= nil, 'der Vorlagenblock selbst ist kein gueltiges Lua: ' .. tostring(err))
  template = loader()
end

do
  local loader, err = load(template, '=rt.lua', 't', {})
  assert_true(loader ~= nil, 'die ausgelieferte rt.lua muss gueltiges Lua sein: ' .. tostring(err))
  local ok, cfg = pcall(loader)
  assert_true(ok and type(cfg) == 'table', 'und eine Tabelle zurueckgeben')
  assert_eq(cfg.engine, nil,
    'die Vorlage darf den entfallenen engine-Schalter nicht wieder mitbringen')
end

-- ══ 3. Der entfallene Schalter kommt nicht zurueck ═════════════════════
--
-- Eine Vorlage, die ein Feld nennt, das niemand mehr liest, waere schlimmer
-- als keine: sie sieht wie eine Wahl aus und ist keine.

do
  local defaults = require('nodes.rt.config')
  assert_eq(defaults.engine, nil,
    'nodes/rt/config.lua darf den engine-Schluessel nicht wieder fuehren')
  assert_true(not template:find('engine', 1, true) or template:find('entfallen', 1, true) ~= nil,
    'die Vorlage darf engine nur noch als entfallen erwaehnen, nicht setzen')

  -- Und der Normalizer raeumt ein Altbestand-Feld weg, statt es zu dulden.
  local normalizer = require('nodes.rt.config_normalizer')
  local real_utils = require('core.utils')
  local utils_stub = {
    normalize_node_id = function(v) return tostring(v or 'RT-1') end,
    deep_copy = real_utils.deep_copy,
  }
  local warnings = {}
  local cfg = { engine = 'v1' }
  normalizer.validate_config(cfg, defaults, function(m) warnings[#warnings + 1] = m end, utils_stub)
  assert_eq(cfg.engine, nil, 'ein altes engine-Feld muss entfernt werden')
  local said_so = false
  for _, w in ipairs(warnings) do
    if tostring(w):find('engine', 1, true) then said_so = true end
  end
  assert_true(said_so, 'und der Betreiber muss erfahren, dass es entfernt wurde')
end

-- ══ 4. Der Pfad ist der, den die Node wirklich liest ════════════════════

do
  local main_src = read('xreactor/nodes/rt/main.lua')
  assert_true(main_src:find('CONFIG.CONFIG_PATH = "/xreactor_config/rt.lua"', 1, true) ~= nil,
    'nodes/rt/main.lua muss genau diese Datei lesen -- sonst legt der Installer'
      .. ' eine Datei an, die niemand anschaut')
end

print('installer_rt_config_template_test.lua: ok')
