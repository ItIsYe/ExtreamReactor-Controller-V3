package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-15): "generell die Water-Node fliegt komplett raus"
-- (die WATER-Rechner sind abgebaut). Diese Datei haelt fest, dass sie
-- nirgends zurueckkommt -- weder als Rolle noch im MASTER -- und dass
-- alte, als WATER beschriftete Log-Disks wieder genutzt werden.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a'); f:close(); return c
end
local function exists(path)
  local f = io.open(path, 'r'); if f then f:close(); return true end; return false
end

-- ══ 1. Keine Rolle WATER mehr ═══════════════════════════════════════════

do
  local constants = require('shared.constants')
  assert_eq(constants.roles.WATER_NODE, nil, 'constants.roles.WATER_NODE ist weg')
  assert_eq(constants.message_types.SET_TARGET, nil, 'SET_TARGET (nur WATER) ist weg')

  assert_true(not exists('xreactor/nodes/water/main.lua'), 'nodes/water/ ist geloescht')

  local manifest = dofile('xreactor/manifest.lua')
  assert_eq(manifest.roles.water, nil, 'kein water-Block im Manifest')
  local function scan(entries)
    for _, e in ipairs(entries or {}) do
      assert_true(not tostring(e.path):find('nodes/water/', 1, true), 'Manifest-Datei unter nodes/water: ' .. tostring(e.path))
      for _, r in ipairs(e.required_for or {}) do
        assert_true(r ~= 'WATER', 'required_for nennt noch WATER: ' .. tostring(e.path))
      end
    end
  end
  scan(manifest.base_files)
  for _, entries in pairs(manifest.roles) do scan(entries) end

  -- Rollenauswahl: Installer, Erststart, Startzuordnung, Plan-Pruefung.
  for _, path in ipairs({ 'xreactor/installer/ui.lua', 'xreactor/core/bootstrap.lua',
                          'xreactor/start.lua', 'xreactor/installer/plan_validator.lua' }) do
    local src = read(path)
    assert_true(not src:find('"WATER"', 1, true) and not src:find('nodes/water/', 1, true)
      and not src:find('label = "WATER"', 1, true), path .. ' bietet WATER nicht mehr an')
  end
  local plan_validator = require('installer.plan_validator')
  assert_eq(plan_validator.ROLE_ENTRYPOINTS.WATER, nil)
end

-- ══ 2. MASTER: keine Wasser-Einstellung, keine Wasser-Anzeige ═══════════

do
  local config_edits = require('master.config_edits')
  assert_eq(config_edits.SETTINGS.water_target, nil, 'Config-Editor: kein Wasser-Ziel mehr')
  for _, path in ipairs({ 'xreactor/master/ui/system_map.lua', 'xreactor/master/ui/resources.lua',
                          'xreactor/master/ui/config_editor.lua', 'xreactor/master/ui/alarms.lua',
                          'xreactor/master/ui/energy.lua', 'xreactor/master/ui_controller.lua',
                          'xreactor/master/support_status.lua', 'xreactor/master/runtime_ops_profile.lua',
                          'xreactor/master/runtime_loop.lua', 'xreactor/master/message_handlers.lua',
                          'xreactor/master/config.lua', 'xreactor/master/init_runtime.lua' }) do
    local src = read(path)
    -- Nur Code, keine Kommentare.
    local code = {}
    for line in (src .. '\n'):gmatch('(.-)\n') do
      if not line:match('^%s*%-%-') then code[#code + 1] = line end
    end
    local text = table.concat(code, '\n')
    assert_true(not text:find('WATER', 1, true) and not text:lower():find('water', 1, true),
      path .. ' enthaelt noch WATER-Code')
  end
end

-- ══ 3. LOG: eine alte WATER-Disk wird wieder vergeben ═══════════════════
--
-- Die Disk-Zuordnung laeuft ueber das Label "XR-<ROLLE>-<slot>". Ohne WATER in
-- ROLE_ORDER gilt "XR-WATER-1" als fremd beschriftet und wird der naechsten
-- Rolle mit freiem Platz zugeteilt; die Labels der anderen Rollen bleiben.

do
  local src = read('xreactor/nodes/log_collector/main.lua')
  local role_order = assert(src:match('local ROLE_ORDER%s*=%s*(%b{})'), 'ROLE_ORDER nicht gefunden')
  local pattern = assert(src:match('local LOG_LABEL_PATTERN%s*=%s*("[^"]*")'), 'LOG_LABEL_PATTERN nicht gefunden')
  local start_pos = assert(src:find('local function parse_label(label)', 1, true))
  local end_pos = assert(src:find('\nend\n', start_pos, true))
  local chunk = 'local ROLE_ORDER = ' .. role_order .. '\nlocal LOG_LABEL_PATTERN = ' .. pattern .. '\n'
    .. src:sub(start_pos, end_pos + 4) .. '\nreturn { parse_label = parse_label, ROLE_ORDER = ROLE_ORDER }\n'
  local mod = assert(load(chunk, '=log_parse_label_slice'))()
  for _, r in ipairs(mod.ROLE_ORDER) do assert_true(r ~= 'WATER', 'ROLE_ORDER ohne WATER') end
  local role, slot = mod.parse_label('XR-WATER-1')
  assert_eq(role, nil, 'eine WATER-Disk gilt als fremd beschriftet und wird neu vergeben')
  role, slot = mod.parse_label('XR-FUEL-2')
  assert_eq(role, 'FUEL', 'die Labels der anderen Rollen bleiben gueltig'); assert_eq(slot, 2)
  role = mod.parse_label('XR-REPROCESSING-1')
  assert_eq(role, 'REPROCESSING')
end

print('water_node_removed_test.lua: ok')
