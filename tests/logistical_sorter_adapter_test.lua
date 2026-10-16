package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- adapters/logistical_sorter.lua gegen eine Sorter-Attrappe, die so streng
-- ist wie der echte Mekanism-Sorter (tests/support/fake_mekanism_sorter.lua).
--
-- Bis v825 nahm die Attrappe hier JEDEN Farbnamen an. Der echte Sorter
-- nimmt nur Mekanisms Konstantennamen (DARK_BLUE, nicht BLUE) -- sieben der
-- 18 Farben der Router-UI scheiterten im Spiel, GRAY setzte Hellgrau und
-- PINK Magenta, und kein Test merkte es.

package.loaded['adapters.logistical_sorter'] = nil

local fake_sorter = require('support.fake_mekanism_sorter')

local devices = {}
local methods_by_name = {
  sorter_0 = { 'setDefaultColor', 'clearDefaultColor', 'getDefaultColor', 'setAutoMode' },
  chest_0  = { 'list', 'size' }, -- not a sorter: must not be detected
  -- Simulates a real Mekanism Logistical Sorter whose in-game security is
  -- still at its default (non-Public) level: getMethods() may omit the
  -- security-gated color methods, while setAutoMode is still listed.
  sorter_limited = { 'setAutoMode', 'getAutoMode' },
  sorter_stuck = { 'setDefaultColor', 'clearDefaultColor', 'getDefaultColor' },
}

local function reset_devices()
  devices.sorter_0 = fake_sorter.new()
  devices.sorter_limited = fake_sorter.new({ public = false })
  devices.sorter_stuck = fake_sorter.new({ ignore_set = true, color = 'RED' })
end
reset_devices()

_G.peripheral = {
  isPresent = function(name) return methods_by_name[name] ~= nil end,
  getMethods = function(name) return methods_by_name[name] end,
  getType = function(name)
    if devices[name] then return 'logisticalSorter' end
    return 'minecraft:chest'
  end,
  call = function(name, method, ...)
    local dev = devices[name]
    if not dev then error('unexpected peripheral.call: ' .. tostring(name) .. '.' .. tostring(method)) end
    return dev.call(method, ...)
  end,
}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual), 2)
  end
end
local function assert_true(v, message) if not v then error(message or 'assert_true failed', 2) end end

local adapter = require('adapters.logistical_sorter')

-- ══ 1. Die Farbliste der Router-UI bleibt, wie sie ist ══════════════════
--
-- Gespeicherte Ziele tragen genau diese Namen -- sie duerfen sich durch die
-- Uebersetzung nicht aendern.

local EXPECTED_COLORS = {
  'BLACK', 'BLUE', 'GREEN', 'CYAN', 'DARK_RED', 'PURPLE', 'ORANGE',
  'LIGHT_GRAY', 'GRAY', 'LIGHT_BLUE', 'LIME', 'AQUA', 'RED', 'MAGENTA',
  'YELLOW', 'WHITE', 'BROWN', 'PINK', 'NONE',
}
assert_eq(#adapter.COLORS, #EXPECTED_COLORS, 'all 18 sorter colors plus NONE')
for i, expected in ipairs(EXPECTED_COLORS) do
  assert_eq(adapter.COLORS[i], expected, 'COLORS[' .. i .. '] must stay the in-game name list')
end

-- ══ 2. Jede Farbe kommt beim echten Sorter an -- als SEINE Farbe ════════
--
-- Name im Spiel -> Mekanisms Konstante, laut EnumColor.java (Mekanism
-- 1.21.x): DARK_BLUE "Blue", DARK_GREEN "Green", DARK_AQUA "Cyan", GRAY
-- "Light Gray", DARK_GRAY "Gray", INDIGO "Light Blue", BRIGHT_GREEN "Lime",
-- PINK "Magenta", BRIGHT_PINK "Pink".

local EXPECTED_MEKANISM = {
  BLACK = 'BLACK', BLUE = 'DARK_BLUE', GREEN = 'DARK_GREEN', CYAN = 'DARK_AQUA',
  DARK_RED = 'DARK_RED', PURPLE = 'PURPLE', ORANGE = 'ORANGE',
  LIGHT_GRAY = 'GRAY', GRAY = 'DARK_GRAY', LIGHT_BLUE = 'INDIGO',
  LIME = 'BRIGHT_GREEN', AQUA = 'AQUA', RED = 'RED', MAGENTA = 'PINK',
  YELLOW = 'YELLOW', WHITE = 'WHITE', BROWN = 'BROWN', PINK = 'BRIGHT_PINK',
}

local sorter = adapter.detect('sorter_0', 'TEST')
assert_true(sorter ~= nil, 'sorter_0 must be detected')
assert_eq(sorter.name, 'sorter_0')
assert_eq(sorter.isValid(), true)

local used = {}
for _, display in ipairs(adapter.COLORS) do
  if display ~= 'NONE' then
    local ok, err = sorter.setDefaultColor(display)
    assert_eq(ok, true, display .. ' must be accepted by the real sorter: ' .. tostring(err))
    assert_eq(devices.sorter_0.color, EXPECTED_MEKANISM[display],
      display .. ' must set Mekanism color ' .. tostring(EXPECTED_MEKANISM[display]))
    assert_eq(adapter.mekanism_name(display), EXPECTED_MEKANISM[display])
    assert_eq(sorter.getDefaultColor(), display, 'getDefaultColor must answer with the in-game name')
    assert_eq(used[devices.sorter_0.color], nil, 'two UI colors must never hit the same sorter color')
    used[devices.sorter_0.color] = true
  end
end
local distinct = 0
for _ in pairs(used) do distinct = distinct + 1 end
assert_eq(distinct, #fake_sorter.ENUM, 'every one of the 18 Mekanism colors is reachable')

-- Gross/klein egal, wie bisher.
assert_eq(sorter.setDefaultColor('aqua'), true)
assert_eq(devices.sorter_0.color, 'AQUA')
assert_eq(sorter.setDefaultColor('light_blue'), true)
assert_eq(devices.sorter_0.color, 'INDIGO')

-- ══ 3. NONE loescht die Farbe ueber clearDefaultColor ═══════════════════

assert_eq(sorter.setDefaultColor('NONE'), true)
assert_eq(devices.sorter_0.color, nil, 'NONE must clear the sorter color')
assert_eq(devices.sorter_0.calls[#devices.sorter_0.calls - 1].method, 'clearDefaultColor',
  'NONE must use clearDefaultColor, not setDefaultColor("NONE")')
assert_eq(sorter.getDefaultColor(), 'NONE')

-- ══ 4. Unbekanntes wird abgelehnt, bevor der Sorter gefragt wird ═══════

local before = #devices.sorter_0.calls
local bad_ok, bad_err = sorter.setDefaultColor('turquoise')
assert_eq(bad_ok, false, 'an unknown color must be rejected')
assert_true(tostring(bad_err):find('invalid_color', 1, true) ~= nil)
assert_eq(#devices.sorter_0.calls, before, 'no peripheral call for an unknown color')

-- ══ 5. Rueckleseprobe: nur true, wenn die Farbe wirklich sitzt ══════════

local stuck = adapter.detect('sorter_stuck', 'TEST')
local stuck_ok, stuck_err = stuck.setDefaultColor('BLUE')
assert_eq(stuck_ok, false, 'a sorter that keeps its old color must be reported')
assert_true(tostring(stuck_err):find('color_not_applied', 1, true) ~= nil, tostring(stuck_err))
assert_true(tostring(stuck_err):find('RED', 1, true) ~= nil, 'the message names what the sorter really carries')

-- ══ 6. Sicherheit nicht oeffentlich: erkannt, aber Fehler beim Setzen ═══

assert_eq(adapter.detect('chest_0', 'TEST'), nil, 'a plain chest must not be detected as a sorter')

local limited = adapter.detect('sorter_limited', 'TEST')
assert_true(limited ~= nil, 'a sorter exposing only setAutoMode (security-limited) must still be detected')
assert_eq(limited.name, 'sorter_limited')
local limited_ok, limited_err = limited.setDefaultColor('red')
assert_eq(limited_ok, false, 'setDefaultColor must still fail against a security-limited sorter')
assert_true(tostring(limited_err):find('security', 1, true) ~= nil,
  'the real security error must surface, not a generic/misleading failure')

-- ══ 7. Alte gespeicherte Namen (vor 2026-09-17) landen beim selben ══════
--      Sorter-Farbton wie damals

assert_eq(adapter.migrate_legacy_color('DARK_BLUE'), 'BLUE')
assert_eq(adapter.migrate_legacy_color('dark_green'), 'GREEN', 'migration must be case-insensitive')
assert_eq(adapter.migrate_legacy_color('DARK_AQUA'), 'CYAN')
assert_eq(adapter.migrate_legacy_color('DARK_GRAY'), 'GRAY')
assert_eq(adapter.migrate_legacy_color('INDIGO'), 'LIGHT_BLUE')
assert_eq(adapter.migrate_legacy_color('BRIGHT_GREEN'), 'LIME')
assert_eq(adapter.migrate_legacy_color('BRIGHT_PINK'), 'PINK')
for _, legacy in ipairs({ 'DARK_BLUE', 'DARK_GREEN', 'DARK_AQUA', 'DARK_GRAY', 'INDIGO', 'BRIGHT_GREEN', 'BRIGHT_PINK' }) do
  assert_eq(adapter.mekanism_name(adapter.migrate_legacy_color(legacy)), legacy,
    legacy .. ' must still reach the very same Mekanism color after migration')
end
assert_eq(adapter.migrate_legacy_color('GRAY'), nil, 'GRAY is a current in-game name, must not be remapped')
assert_eq(adapter.migrate_legacy_color('PINK'), nil, 'PINK is a current in-game name, must not be remapped')
assert_eq(adapter.migrate_legacy_color('NOT_A_COLOR'), nil)
assert_eq(adapter.migrate_legacy_color(nil), nil)

assert_eq(adapter.is_valid_color('RED'), true)
assert_eq(adapter.is_valid_color('red'), true, 'lowercase must also validate (case-insensitive)')
assert_eq(adapter.is_valid_color('NONE'), true)
assert_eq(adapter.is_valid_color('NOT_A_COLOR'), false)
assert_eq(adapter.is_valid_color(nil), false)
assert_eq(adapter.is_valid_color(42), false)

assert_eq(adapter.display_name(nil), 'NONE')
assert_eq(adapter.display_name('dark_blue'), 'BLUE')
assert_eq(adapter.display_name('BOGUS'), nil)

print('logistical_sorter_adapter_test.lua: ok')
