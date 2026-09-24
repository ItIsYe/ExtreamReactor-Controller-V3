-- tests/installer_node_footprint_test.lua
--
-- Was auf einem Knoten landet, und was nicht.
--
-- Anlass: eine RT-Installation brach aus Platzmangel an der letzten Datei
-- ab (manifest.lua, 22,7 kB, bei 13,2 kB frei). Dabei liegen auf jedem
-- Knoten rund 95 kB, die dort nie gelesen werden -- die Installermodule
-- und das Manifest selbst. Der Bootstrap /installer laedt seine Module
-- bei jedem Lauf frisch von GitHub, auto_update.lua und start.lua's
-- Recovery ebenso; die Buildkennung kommt aus release.lua.
--
-- Diese Datei haelt beide Richtungen fest: dass die ungenutzten Dateien
-- draussen bleiben, und -- wichtiger -- dass genau die drei, die ein
-- laufender Knoten wirklich braucht, drin bleiben.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

package.loaded['installer.manifest'] = nil
local manifest_mod = require('installer.manifest')
local manifest = assert(dofile('xreactor/manifest.lua'), 'Manifest nicht ladbar')

local expected = manifest_mod.files_for_role(manifest, 'RT', {})

-- ── 1. Was ein laufender Knoten liest, MUSS installiert werden ───────────
--
-- Diese drei sind der ganze Grund, warum installer/ ueberhaupt noch auf
-- die Platte kommt. Faellt eine davon heraus, startet der Knoten nicht
-- mehr oder aktualisiert sich nie wieder.

for _, path in ipairs({
  'start.lua',                    -- /startup.lua ruft es auf
  'release.lua',                  -- shared/build_info.lua liest die Buildkennung
  'installer/auto_update.lua',    -- start.lua laedt es
  'core/update_handshake.lua',    -- start.lua per dofile
  'nodes/rt/main.lua',            -- der Einstieg der Rolle
}) do
  assert_true(expected[path] ~= nil, 'MUSS installiert werden: ' .. path)
end

-- Ampel und Sprecher haengen an einer Auswahl bei der Installation
-- (optional=true). Sie werden per pcall(require, ...) geladen -- also
-- muessen sie da sein, WENN die Funktion gewaehlt wurde, und sie duerfen
-- sonst fehlen, ohne dass etwas bricht.
do
  local with_features = manifest_mod.files_for_role(manifest, 'RT',
    { ampel = true, speaker_alarm = true })
  assert_true(with_features['optional/ampel.lua'] ~= nil,
    'gewaehlte Ampel muss installiert werden')
  assert_true(with_features['optional/speaker_alarm.lua'] ~= nil,
    'gewaehlter Sprecher muss installiert werden')
  assert_true(expected['optional/ampel.lua'] == nil,
    'ohne Auswahl bleibt die Ampel draussen')
end

-- ── 2. Was nie gelesen wird, bleibt draussen ─────────────────────────────

local skipped = {
  'installer/http.lua', 'installer/init.lua', 'installer/journal.lua',
  'installer/manifest.lua', 'installer/plan_validator.lua',
  'installer/reactor_naming.lua', 'installer/stage.lua', 'installer/ui.lua',
  'manifest.lua',
}
for _, path in ipairs(skipped) do
  assert_true(expected[path] == nil,
    path .. ' wird auf dem Knoten nie gelesen und darf nicht installiert werden')
end

-- ── 3. Und das ist genau der Grund, warum es sicher ist ──────────────────
--
-- Der Verzicht traegt nur, solange kein Knoten-Code eines dieser Module
-- von der Platte laedt. Faengt jemand damit an, muss dieser Test
-- fehlschlagen -- sonst bricht es erst im Spiel auf, und zwar beim
-- naechsten Update aller Knoten gleichzeitig.

local function read(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read('*a'); f:close(); return s
end

do
  -- Nur echter Code, keine Kommentarzeilen (die Datei erklaert an mehreren
  -- Stellen, WARUM sie installer/journal.lua NICHT laedt).
  local code = {}
  for line in read('xreactor/start.lua'):gmatch('[^\n]*') do
    if not line:match('^%s*%-%-') then code[#code + 1] = line end
  end
  code = table.concat(code, '\n')

  for _, path in ipairs(skipped) do
    assert_true(code:find(path, 1, true) == nil,
      'start.lua darf ' .. path .. ' nicht von der Platte laden -- sonst darf es'
        .. ' auch nicht aus der Installation genommen werden')
  end
  assert_true(code:find('installer/auto_update.lua', 1, true) ~= nil,
    'start.lua muss auto_update.lua weiterhin lokal laden -- sonst stimmt die'
      .. ' Begruendung fuer den Rest dieses Tests nicht mehr')
end

do
  -- Und der Bootstrap, der beim Update laeuft, muss seine Module weiterhin
  -- HERUNTERLADEN statt sie lokal zu erwarten.
  local boot = read('installer')
  assert_true(boot:find('download(base.."installer/init.lua")', 1, true) ~= nil,
    '/installer muss installer/init.lua herunterladen -- lokal gibt es sie nicht mehr')
end

-- ── 4. Was es unterm Strich bringt ───────────────────────────────────────

do
  local size = {}
  for _, group in pairs({ manifest.base_files or {} }) do
    for _, e in ipairs(group) do size[e.path] = tonumber(e.size_bytes) or 0 end
  end
  for _, entries in pairs(manifest.roles or {}) do
    for _, e in ipairs(entries or {}) do size[e.path] = tonumber(e.size_bytes) or 0 end
  end

  local installed = 0
  for path in pairs(expected) do installed = installed + (size[path] or 0) end
  local saved = 0
  for _, path in ipairs(skipped) do saved = saved + (size[path] or 0) end

  assert_true(saved > 60000, string.format(
    'die Ersparnis soll spuerbar sein, war %d Bytes', saved))
  assert_true(installed > 300000, string.format(
    'und die Rolle RT muss trotzdem vollstaendig sein, waren nur %d Bytes', installed))
end

print('installer_node_footprint_test.lua: ok')
