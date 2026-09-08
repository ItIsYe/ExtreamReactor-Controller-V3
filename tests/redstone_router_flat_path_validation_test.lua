package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for M.validate_tree()/normalize_with_errors() in the flat
-- 'path' format (see nodes/fuel/redstone_router.lua). Covers the validation
-- cases specific to this format (a standalone 'path' field per route), the
-- overarching rules that still apply (duplicate reactor ids, identical --
-- i.e. indistinguishable -- paths between two routes), and the "side"
-- removal (2026-09-03): a path entry is now just the VALVE-Node id itself
-- (a string), or, for backward compatibility with already-deployed configs,
-- an old {side=,integrator=} step table with 'side' ignored -- but every
-- entry now requires a real 'integrator', since the bare-redstone-side
-- actuation path (no VALVE-Node at all) no longer exists.

local redstone_router = require('nodes.fuel.redstone_router')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function has_error_code(errors, code)
  for _, e in ipairs(errors) do if e.code == code then return true end end
  return false
end

-- ── Gueltige, geteilte Routen sind KEIN Fehler (das ist der beabsichtigte ──
--    Weg, ein Ventil mehreren Reaktoren zuzuordnen). ────────────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { 'VALVE-TRUNK', 'VALVE-R1' } },
    { reactor = 'R2', label = 'B', path = { 'VALVE-TRUNK', 'VALVE-R2' } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(result.ok, 'a valve shared across two routes must be valid, not an error: ' .. (result.errors[1] and result.errors[1].message or ''))
end

-- ── Alte {side=,integrator=}-Schritt-Tabellen bleiben gueltig -- 'side' ─────
--    wird schlicht ignoriert. ───────────────────────────────────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { { side = 'back', integrator = 'VALVE-1' } } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(result.ok, 'a legacy {side=,integrator=} step must still be accepted, side ignored: '
    .. (result.errors[1] and result.errors[1].message or ''))
end

-- ── path ist keine Tabelle ───────────────────────────────────────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = 'not a table' } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a non-table path must be rejected')
  assert_true(has_error_code(result.errors, 'invalid_path'), 'expected invalid_path, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── ein Pfadschritt ohne VALVE-Node-ID (integrator) ─────────────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = { {} } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a path step without an integrator (VALVE-Node id) must be rejected')
  assert_true(has_error_code(result.errors, 'missing_integrator'), 'expected missing_integrator, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── ein leerer String als VALVE-Node-ID ist ebenso ungueltig ────────────────
do
  local routes = { { reactor = 'R1', label = 'A', path = { '' } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'an empty-string path entry must be rejected')
  assert_true(has_error_code(result.errors, 'missing_integrator'), 'expected missing_integrator, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── weder reactor noch label -- nicht adressierbar ──────────────────────────
do
  local routes = { { path = { 'VALVE-1' } } }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a route without any target identity must be rejected')
  assert_true(has_error_code(result.errors, 'missing_target'), 'expected missing_target, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── doppelte Reaktor-ID ──────────────────────────────────────────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { 'VALVE-1' } },
    { reactor = 'R1', label = 'B', path = { 'VALVE-2' } },
  }
  local result = redstone_router.validate_tree(routes)
  assert_true(not result.ok, 'a duplicate reactor id must be rejected')
  assert_true(has_error_code(result.errors, 'duplicate_reactor'), 'expected duplicate_reactor, got: ' .. (result.errors[1] and result.errors[1].code or '?'))
end

-- ── identische Pfade zweier Routen sind nicht unterscheidbar ────────────────
do
  local routes = {
    { reactor = 'R1', label = 'A', path = { 'VALVE-TRUNK', 'VALVE-LEFT' } },
    { reactor = 'R2', label = 'B', path = { 'VALVE-TRUNK', 'VALVE-LEFT' } },
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
