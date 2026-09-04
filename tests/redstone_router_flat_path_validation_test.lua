package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer M.validate_tree()/normalize_with_errors() im NEUEN
-- flachen 'path'-Format (siehe nodes/fuel/redstone_router.lua, Fix
-- 2026-07-19). Deckt die Validierungsfaelle ab, die es im alten
-- verschachtelten Baumformat so nicht gab (eigenstaendiges 'path'-Feld
-- pro Route), sowie die weiterhin geltenden uebergreifenden Regeln
-- (doppelte Reaktor-IDs, identische -- also nicht unterscheidbare --
-- Pfade zwischen zwei Routen).

local redstone_router = require('nodes.fuel.redstone_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function has_error_code(errors, code)
  for _, e in ipairs(errors) do if e.code == code then return true end end
  return false
end

-- ── Gueltige, geteilte Routen sind KEIN Fehler mehr (das ist jetzt der ─────
--    beabsichtigte Weg, ein Ventil mehreren Reaktoren zuzuordnen). ─────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { { side = 'back' }, { side = 'right' } } },
    { reactor = 'R2', label = 'B', path = { { side = 'back' }, { side = 'left' } } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(result.ok, 'a valve shared across two routes must be valid, not an error: ' .. (result.errors[1] and result.errors[1].message or ''))
end

-- ── path ist keine Tabelle ───────────────────────────────────────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = 'not a table' } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a non-table path must be rejected')
  assert_true(has_error_code(result.errors, 'invalid_path'), 'expected invalid_path, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── ein Pfadschritt ohne 'side' ──────────────────────────────────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = { { integrator = 'VALVE-1' } } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a path step without a side must be rejected')
  assert_true(has_error_code(result.errors, 'invalid_path_step'), 'expected invalid_path_step, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── ein Pfadschritt mit ungueltiger Seite ────────────────────────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = { { side = 'diagonal' } } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'an invalid side value must be rejected')
  assert_true(has_error_code(result.errors, 'invalid_side'), 'expected invalid_side, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── weder reactor noch label -- nicht adressierbar ──────────────────────────
do
  local routes = { { path = { { side = 'back' } } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a route without any target identity must be rejected')
  assert_true(has_error_code(result.errors, 'missing_target'), 'expected missing_target, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── doppelte Reaktor-ID ──────────────────────────────────────────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { { side = 'back' } } },
    { reactor = 'R1', label = 'B', path = { { side = 'front' } } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a duplicate reactor id must be rejected')
  assert_true(has_error_code(result.errors, 'duplicate_reactor'), 'expected duplicate_reactor, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── identische Pfade zweier Routen sind nicht unterscheidbar ────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { { side = 'back' }, { side = 'left' } } },
    { reactor = 'R2', label = 'B', path = { { side = 'back' }, { side = 'left' } } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'two routes with an identical valve path must be rejected (indistinguishable)')
  assert_true(has_error_code(result.errors, 'identical_paths'), 'expected identical_paths, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── ein Reaktor ohne jedes Ventil (path={}) ist weiterhin gueltig ───────────
do
  local routes = { { reactor = 'R1', label = 'A', path = {} } }
  local result = redstone_router.validate_tree(routes)
  assert_true(result.ok, 'a reactor with an empty path (no valve gating) must remain valid: ' .. (result.errors[1] and result.errors[1].message or ''))
end

print("redstone_router_flat_path_validation_test.lua: ok")
