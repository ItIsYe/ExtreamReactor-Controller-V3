package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pruefung der installierten Dateien gegen ihre Pruefsummen
-- (core/install_integrity.lua, Pruefsummenliste von installer/manifest.lua).
--
--   1. die CRC32 des Knotens ist dieselbe wie die des Manifests -- fuer JEDE
--      Datei im Repo, auch fuer die mit Umlauten und Rahmenzeichen. Waere sie
--      es nicht, meldete jeder Knoten Abweichungen und installierte endlos
--      neu.
--   2. die Liste, die der Installer schreibt, ist ladbar und vollstaendig
--   3. check(): passt / veraendert / abgeschnitten / fehlt / keine Liste
--   4. decide_repair(): hoechstens eine Reparatur je Fassung und Abklingzeit

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

-- Kein CC-Yield im Host-Lua.
os.queueEvent, os.pullEvent = nil, nil

local integrity = require('core.install_integrity')
local installer_manifest = require('installer.manifest')

local function read_bytes(path)
  local f = assert(io.open(path, 'rb'))
  local c = f:read('*a')
  f:close()
  return c
end

-- ══ 1. Dieselbe CRC32 wie das Manifest ════════════════════════════════════
local manifest = assert(load(read_bytes('xreactor/manifest.lua'), '=manifest', 't', {}))()
local entries = {}
for _, e in ipairs(manifest.base_files or {}) do entries[#entries + 1] = e end
for _, list in pairs(manifest.roles or {}) do
  for _, e in ipairs(list) do entries[#entries + 1] = e end
end
local non_ascii = 0
for _, e in ipairs(entries) do
  local content = read_bytes('xreactor/' .. e.path)
  if content:find('[\128-\255]') then non_ascii = non_ascii + 1 end
  assert_eq(integrity.crc32(content), e.hash, 'CRC32 von ' .. e.path)
  assert_eq(#content, e.size_bytes, 'Groesse von ' .. e.path)
end
assert_true(#entries > 100, 'das Manifest muss gelesen worden sein')
assert_true(non_ascii > 0, 'unter den Dateien muessen auch welche mit Nicht-ASCII-Zeichen sein')
assert_eq(integrity.crc32('xreactor Ä ─'), installer_manifest.crc32('xreactor Ä ─'),
  'core/install_integrity.lua und installer/manifest.lua rechnen dieselbe CRC32')

-- ══ 2. Die Liste des Installers ═══════════════════════════════════════════
local expected = installer_manifest.files_for_role(manifest, 'RT', {})
local rendered = installer_manifest.render_install_hashes(manifest, expected, 'RT')
local hashes = assert(load(rendered, '=install_hashes', 't', {}))()
assert_eq(hashes.manifest_id, manifest.manifest_id, 'Fassung in der Liste')
assert_eq(hashes.payload_digest, manifest.payload_digest, 'Inhalts-Pruefsumme in der Liste')
assert_eq(hashes.role, 'RT', 'Rolle in der Liste')
local listed = 0
for rel, entry in pairs(expected) do
  listed = listed + 1
  local item = hashes.files[rel]
  assert_true(item ~= nil, 'die Liste muss ' .. rel .. ' enthalten')
  if entry.hash then assert_eq(item.hash, entry.hash, 'Hash von ' .. rel .. ' in der Liste') end
  if entry.size_bytes then assert_eq(item.size, entry.size_bytes, 'Groesse von ' .. rel .. ' in der Liste') end
end
local in_list = 0
for _ in pairs(hashes.files) do in_list = in_list + 1 end
assert_eq(in_list, listed, 'die Liste enthaelt genau die installierten Dateien')

-- ══ 3. check() ════════════════════════════════════════════════════════════
local disk = {}
_G.fs = {
  exists = function(p) return disk[p] ~= nil end,
  open = function(p, mode)
    if mode ~= 'r' or disk[p] == nil then return nil end
    return { readAll = function() return disk[p] end, close = function() end }
  end,
}
local function install(files)
  disk = {}
  local fake_expected = {}
  for rel, content in pairs(files) do
    disk['/xreactor/' .. rel] = content
    fake_expected[rel] = { path = rel, size_bytes = #content, hash = integrity.crc32(content) }
  end
  disk['/xreactor/install_hashes.lua'] = installer_manifest.render_install_hashes(
    { manifest_id = 'manifest-v900', manifest_version = 900, payload_digest = 'abcdef12' }, fake_expected, 'RT')
end

install({ ['start.lua'] = 'print("start")\n', ['core/a.lua'] = 'return 1\n', ['core/b.lua'] = '-- Ä\nreturn 2\n' })
local r = integrity.check()
assert_eq(r.ok, true, 'unveraenderte Dateien passen')
assert_eq(r.checked, 3, 'alle drei geprueft')
assert_eq(r.payload_digest, 'abcdef12', 'Pruefsumme der Fassung im Ergebnis')
assert_true(integrity.describe(r):find('3 Dateien passen zu manifest-v900', 1, true) ~= nil,
  'Meldung bei Erfolg: ' .. integrity.describe(r))

disk['/xreactor/core/a.lua'] = 'return 9\n'           -- gleiche Groesse, anderer Inhalt
r = integrity.check()
assert_eq(r.ok, false, 'veraenderte Datei muss auffallen')
assert_eq(#r.changed, 1, 'genau eine veraendert')
assert_eq(r.changed[1], 'core/a.lua', 'die veraenderte Datei')

disk['/xreactor/core/a.lua'] = 'return 1\n'
disk['/xreactor/core/b.lua'] = '-- Ä\n'               -- abgeschnitten
r = integrity.check()
assert_eq(r.ok, false, 'abgeschnittene Datei muss auffallen')
assert_eq(r.changed[1], 'core/b.lua', 'die abgeschnittene Datei')

disk['/xreactor/core/b.lua'] = nil                     -- fehlt
r = integrity.check()
assert_eq(r.ok, false, 'fehlende Datei muss auffallen')
assert_eq(r.missing[1], 'core/b.lua', 'die fehlende Datei')
assert_true(integrity.describe(r):find('passen NICHT', 1, true) ~= nil, 'Meldung bei Abweichung')

disk['/xreactor/install_hashes.lua'] = nil
r = integrity.check()
assert_eq(r.ok, nil, 'ohne Liste: unbekannt, nicht "kaputt"')

-- ══ 4. decide_repair() ════════════════════════════════════════════════════
local bad = { ok = false, payload_digest = 'abcdef12', manifest_id = 'manifest-v900' }
local hour = 3600 * 1000
local allowed, state = integrity.decide_repair(bad, nil, 10 * hour, 6 * 3600)
assert_true(allowed, 'die erste Reparatur ist erlaubt')
assert_eq(state.key, 'abcdef12', 'gemerkt wird die Fassung')
allowed = integrity.decide_repair(bad, state, 11 * hour, 6 * 3600)
assert_true(not allowed, 'innerhalb der Abklingzeit keine zweite Reparatur derselben Fassung')
allowed = integrity.decide_repair(bad, state, 16 * hour + 1, 6 * 3600)
assert_true(allowed, 'nach der Abklingzeit wieder erlaubt')
allowed = integrity.decide_repair({ ok = false, payload_digest = '12345678' }, state, 11 * hour, 6 * 3600)
assert_true(allowed, 'eine andere Fassung darf sofort repariert werden')
allowed = integrity.decide_repair({ ok = true, payload_digest = 'abcdef12' }, nil, 11 * hour, 6 * 3600)
assert_true(not allowed, 'passende Dateien brauchen keine Reparatur')
allowed = integrity.decide_repair({ ok = nil }, nil, 11 * hour, 6 * 3600)
assert_true(not allowed, 'ohne Liste keine Reparatur')

-- ══ 5. Der Installer schreibt die Liste -- an der richtigen Stelle ═════════
--
-- Nach der Verifikation der Dateien, VOR release.lua und dem Abschluss des
-- Journals: eine abgeschlossene Installation hat die Liste immer. Und sie
-- ist in der Platzrechnung enthalten (an fehlendem Platz ist im Feld schon
-- eine Installation gescheitert).
do
  local src = read_bytes('xreactor/installer/init.lua')
  local function pos(needle)
    local p = src:find(needle, 1, true)
    assert_true(p ~= nil, 'installer/init.lua: Marker fehlt: ' .. needle)
    return p
  end
  local verify = pos('Verifikation fehlgeschlagen, Datei fehlt nach Installation')
  local write_hashes = pos('INSTALL_ROOT .. "/install_hashes.lua"')
  local release = pos('local release_entry = expected["release.lua"]')
  local commit = pos('state = journal_mod.STATE.COMMITTED')
  assert_true(verify < write_hashes and write_hashes < release and release < commit,
    'install_hashes.lua muss nach der Verifikation und vor release.lua/COMMITTED geschrieben werden')
  assert_true(pos('planned_bytes = planned_bytes + (install_hashes and #install_hashes or 0)')
      < pos('stage_mod.check_capacity(planned_bytes, INSTALL_ROOT)'),
    'die Liste muss in der Platzrechnung vor der Kapazitaetspruefung stehen')
end

print('ok install_integrity_test')
