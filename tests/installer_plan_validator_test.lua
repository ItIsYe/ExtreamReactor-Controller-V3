package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL/MANIFEST-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 7 "Vorabvalidierung ist zu schwach").
-- Treibt das echte installer/plan_validator.lua-Modul direkt: jede der
-- gefordeten strukturellen Bedingungen (erlaubte Rollenwerte, erwarteter
-- Entrypoint, doppelte Pfade, absolute Pfade/".."-Traversal, gueltige
-- Hash-/Groessenfelder, Manifest-Selbstkonsistenz, maximale Groesse) muss
-- den GESAMTEN Plan ablehnen, sobald sie verletzt ist -- und ein
-- vollstaendig valider Plan muss akzeptiert werden.

local plan_validator = require('installer.plan_validator')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function assert_false(value, message)
  if value then error(message or 'assert_false failed') end
end

local function valid_files()
  return {
    ['nodes/fuel/main.lua'] = { size_bytes = 1000, hash = 'deadbeef' },
    ['shared/constants.lua'] = { size_bytes = 500, hash = 'cafebabe' },
  }
end

local function valid_manifest()
  return { manifest_id = 'manifest-v470', manifest_version = 470 }
end

-- 1. Ein vollstaendig valider Plan wird akzeptiert.
do
  local ok, err = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = valid_files(),
  })
  assert_true(ok, 'a fully valid plan must be accepted, got error: ' .. tostring(err))
end

-- 2. Unbekannte Rolle wird abgelehnt.
do
  local ok = plan_validator.validate({
    role = { key = 'ghost', label = 'GHOST-ROLE' },
    manifest = valid_manifest(),
    files = valid_files(),
  })
  assert_false(ok, 'an unknown role must be rejected')
end

-- 3. Fehlender Rollen-Entrypoint wird abgelehnt.
do
  local files = { ['shared/constants.lua'] = { size_bytes = 500, hash = 'cafebabe' } }
  local ok, err = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'a plan missing the role entrypoint (nodes/fuel/main.lua) must be rejected')
  assert_true(err:find('Entrypoint', 1, true) ~= nil, 'error must mention the missing entrypoint: ' .. tostring(err))
end

-- 4. Absoluter Pfad wird abgelehnt.
do
  local files = valid_files()
  files['/etc/passwd'] = { size_bytes = 10, hash = 'deadbeef' }
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'an absolute path must be rejected')
end

-- 5. ".."-Traversal wird abgelehnt.
do
  local files = valid_files()
  files['../../etc/passwd'] = { size_bytes = 10, hash = 'deadbeef' }
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'a ".." traversal path must be rejected')
end

-- 6. Ungueltiges hash-Feld (falsche Laenge / kein Hex) wird abgelehnt.
do
  local files = valid_files()
  files['nodes/fuel/main.lua'].hash = 'not-hex!'
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'a malformed hash field must be rejected')
end

-- 7. Fehlendes/negatives size_bytes wird abgelehnt.
do
  local files = valid_files()
  files['nodes/fuel/main.lua'].size_bytes = -5
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'a negative size_bytes must be rejected')
end

-- 8. Ueberdimensionierte Einzeldatei wird abgelehnt.
do
  local files = valid_files()
  files['nodes/fuel/main.lua'].size_bytes = plan_validator.MAX_FILE_SIZE_BYTES + 1
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_false(ok, 'a file larger than MAX_FILE_SIZE_BYTES must be rejected')
end

-- 9. Manifest-Inkonsistenz (manifest_id passt nicht zu manifest_version)
--    wird abgelehnt.
do
  local ok = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = { manifest_id = 'manifest-v123', manifest_version = 470 },
    files = valid_files(),
  })
  assert_false(ok, 'a manifest_id/manifest_version mismatch must be rejected')
end

-- 10. Fehlendes hash-Feld (nil) ist ERLAUBT (z.B. lokal generierte
--     role.lua-Inhalte ohne Manifest-Hash) -- nur ein VORHANDENES,
--     fehlerhaftes hash-Feld wird abgelehnt.
do
  local files = {
    ['nodes/fuel/main.lua'] = { size_bytes = 1000, hash = 'deadbeef' },
    ['config/role.lua'] = { size_bytes = 40 },  -- kein hash-Feld
  }
  local ok, err = plan_validator.validate({
    role = { key = 'fuel', label = 'FUEL' },
    manifest = valid_manifest(),
    files = files,
  })
  assert_true(ok, 'a missing (nil) hash field must be allowed, got error: ' .. tostring(err))
end

-- 11. plan_validator.ROLE_ENTRYPOINTS deckt exakt dieselben Rollen und
--     Entrypoints ab wie xreactor/start.lua's ROLE_ENTRY -- strukturelle
--     Synchronitaetspruefung direkt am Quelltext, damit beide Listen nicht
--     auseinanderlaufen (start.lua ist ein eigenstaendiges Top-Level-Skript,
--     kein importierbares Modul -- deshalb kein einzelner Code-Ort moeglich).
do
  local function read(path)
    local f = assert(io.open(path, 'r'))
    local c = f:read('*a')
    f:close()
    return c
  end
  local repo_root = os.getenv('REPO_ROOT') or '.'
  local start_src = read(repo_root .. '/xreactor/start.lua')
  for role_label, entrypoint in pairs(plan_validator.ROLE_ENTRYPOINTS) do
    -- Whitespace vor "=" ist in start.lua's ROLE_ENTRY-Tabelle nicht
    -- exakt festgelegt -- robuster Musterabgleich statt fixem Padding.
    local pattern = role_label .. '%s*=%s*INSTALL_ROOT%s*%.%.%s*"/' .. entrypoint:gsub('%.', '%%.') .. '"'
    assert_true(start_src:find(pattern) ~= nil,
      'start.lua ROLE_ENTRY must map ' .. role_label .. ' to ' .. entrypoint .. ' (plan_validator.ROLE_ENTRYPOINTS drifted out of sync)')
  end
end

-- 12. Verdrahtung: installer/init.lua (seit INSTALL-P1/Abschnitt 8 die
--     EINZIGE Stelle mit tatsaechlicher Installationslogik) muss
--     plan_validator_mod.validate() aufrufen, und zwar VOR dem ersten
--     destruktiven Schritt ("Alte Installation loeschen").
do
  local function read(path)
    local f = assert(io.open(path, 'r'))
    local c = f:read('*a')
    f:close()
    return c
  end
  local repo_root = os.getenv('REPO_ROOT') or '.'

  local function check_ordering(src, label, search_from)
    search_from = search_from or 1
    local validate_pos = src:find('plan_validator_mod.validate(', search_from, true)
    assert_true(validate_pos ~= nil, label .. ': plan_validator_mod.validate() call not found')
    local delete_pos = src:find('Alte Installation', validate_pos, true)
    assert_true(delete_pos ~= nil, label .. ': "Alte Installation" delete marker not found after validate() call')
  end

  check_ordering(read(repo_root .. '/xreactor/installer/init.lua'), 'installer/init.lua')
end

print('installer_plan_validator_test.lua: ok')
