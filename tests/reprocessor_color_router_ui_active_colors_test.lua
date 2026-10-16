package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for the FARBEN page (2026-09-17): the operator
-- wants to restrict which Sorter colors are even offered when cycling a
-- target's color (< / >) to a curated subset of the confirmed real color
-- list (adapters/logistical_sorter.lua's COLORS, minus "NONE" -- that is
-- the Sorter's own "no color set" state, never a real routing color).
-- Tapping a color on this page toggles it active/inactive immediately in
-- the working copy; SPEICHERN persists the active set (config.feed.
-- active_colors) and color_prev/color_next only ever land on active
-- colors afterwards.

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = { get = function(name) return name end }

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' end,
  getNames = function() return { 'sorter_0' } end,
  getType = function() return 'logisticalSorter' end,
  getMethods = function() return { 'setDefaultColor', 'getDefaultColor' } end,
}

local function new_mon(w, h)
  return {
    getSize = function() return w, h end,
    setCursorPos = function() end,
    setTextColor = function() end,
    setBackgroundColor = function() end,
    write = function() end,
    clear = function() end,
  }
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local color_router_ui = require('nodes.reprocessor.color_router_ui')
local logistical_sorter = require('adapters.logistical_sorter')

local function find_button(ui, action, index)
  for _, btn in ipairs(ui.buttons) do
    if btn.action == action and (index == nil or btn.index == index) then
      return btn
    end
  end
  return nil
end

local function find_toggle(ui, color_name)
  for _, btn in ipairs(ui.buttons) do
    if btn.action == 'color_toggle' and btn.name == color_name then return btn end
  end
  return nil
end

local written = nil
local write_config = function(path, data)
  written = { path = path, data = data }
  return true
end

local config = { feed = { sorter = 'sorter_0', targets = {
  { label = 'Reprocessor A', color = 'RED' },
} } }

local ui = color_router_ui.new({ config = config, write_config = write_config, log = function() end })
local mon = new_mon(80, 30)

-- Without any saved active_colors, everything defaults to active --
-- backward compatible with configs saved before this feature existed.
ui:render(mon, nil, nil, true)
local real_color_count = #logistical_sorter.COLORS - 1 -- minus NONE
local colors_open_btn = find_button(ui, 'colors_open')
assert_true(colors_open_btn ~= nil, 'expected a FARBEN button on the list page')
assert_true(ui:handle_touch(colors_open_btn.x1, colors_open_btn.y) == true)
assert_eq(ui.mode, 'colors')

ui:render(mon, nil, nil, true)
local toggle_count = 0
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'color_toggle' then toggle_count = toggle_count + 1 end
end
assert_eq(toggle_count, real_color_count, 'expected one toggle row per real color (NONE excluded)')

-- NONE must never appear as a toggleable row.
assert_true(find_toggle(ui, 'NONE') == nil, 'NONE must not be offered on the FARBEN page')

-- Deactivate AQUA and BLUE.
local aqua_toggle = find_toggle(ui, 'AQUA')
assert_true(aqua_toggle ~= nil)
assert_true(ui:handle_touch(aqua_toggle.x1, aqua_toggle.y) == true)
assert_eq(ui.active_colors['AQUA'], false)
assert_eq(ui.dirty, true, 'toggling a color must mark the working copy dirty')

ui:render(mon, nil, nil, true)
local blue_toggle = find_toggle(ui, 'BLUE')
assert_true(blue_toggle ~= nil)
assert_true(ui:handle_touch(blue_toggle.x1, blue_toggle.y) == true)
assert_eq(ui.active_colors['BLUE'], false)

-- ZURUECK returns to the list page.
ui:render(mon, nil, nil, true)
local back_btn = find_button(ui, 'colors_back')
assert_true(back_btn ~= nil)
assert_true(ui:handle_touch(back_btn.x1, back_btn.y) == true)
assert_eq(ui.mode, 'list')

-- Cycling target 1's color (starting at RED) must now skip AQUA and BLUE.
ui:render(mon, nil, nil, true)
for _ = 1, real_color_count do
  local next_btn = find_button(ui, 'color_next', 1)
  assert_true(next_btn ~= nil)
  assert_true(ui:handle_touch((next_btn.x1 + next_btn.x2) / 2, next_btn.y) == true)
  assert_true(ui.targets[1].color ~= 'AQUA', 'color_next must never land on a deactivated color (AQUA)')
  assert_true(ui.targets[1].color ~= 'BLUE', 'color_next must never land on a deactivated color (BLUE)')
  ui:render(mon, nil, nil, true)
end

-- Save must persist exactly the active colors (real_color_count - 2).
local save_btn = find_button(ui, 'save')
assert_true(save_btn ~= nil)
assert_true(ui:handle_touch(save_btn.x1, save_btn.y) == true)
assert_true(written ~= nil, 'save must call write_config')
assert_eq(#written.data.active_colors, real_color_count - 2, 'the persisted active_colors list must exclude AQUA and BLUE')
local found_aqua, found_blue = false, false
for _, c in ipairs(written.data.active_colors) do
  if c == 'AQUA' then found_aqua = true end
  if c == 'BLUE' then found_blue = true end
end
assert_true(not found_aqua and not found_blue, 'AQUA/BLUE must not be in the persisted active_colors list')
assert_eq(config.feed.active_colors, written.data.active_colors)

-- Reloading a fresh UI instance from that same config must restore the
-- deactivated state (not re-default everything back to active).
local ui2 = color_router_ui.new({ config = config, write_config = write_config, log = function() end })
assert_eq(ui2.active_colors['AQUA'] or false, false, 'AQUA must reload as inactive')
assert_eq(ui2.active_colors['BLUE'] or false, false, 'BLUE must reload as inactive')
assert_eq(ui2.active_colors['RED'], true, 'RED must reload as still active')

print('reprocessor_color_router_ui_active_colors_test.lua: ok')
