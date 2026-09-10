package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for nodes/reprocessor/color_router_ui.lua's compact
-- layout: REPROCESSOR usually has NO external monitor, so main.lua falls
-- back to the node's own computer terminal (a fixed 51x19 screen, see
-- nodes/valve/local_ui.lua's EXPECTED_W/EXPECTED_H). Before this test the
-- Router page required a 62x16 monitor and would show nothing but a "too
-- small" warning on a plain 51x19 computer -- this proves the page is now
-- fully usable at that size: every control renders inside bounds, no two
-- buttons overlap, and the full sorter/ziel/kiste/target/save flow works
-- via touch exactly like on a wide monitor.

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = { get = function(name) return name end }

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'ender_chest_1' end,
  getNames = function() return { 'sorter_0', 'ender_chest_1' } end,
  getType = function(name)
    if name == 'sorter_0' then return 'logisticalSorter' end
    return 'minecraft:chest'
  end,
  getMethods = function(name)
    if name == 'sorter_0' then return { 'setDefaultColor', 'getDefaultColor' } end
    return {}
  end,
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

local function find_button(ui, action, index)
  for _, btn in ipairs(ui.buttons) do
    if btn.action == action and (index == nil or btn.index == index) then
      return btn
    end
  end
  return nil
end

-- No two buttons on the current page may share screen cells -- the real
-- symptom of a layout that doesn't fit is overlapping touch zones, not
-- just visual overlap.
local function assert_no_overlaps(ui, w)
  for _, btn in ipairs(ui.buttons) do
    assert_true(btn.x1 >= 1 and btn.x2 <= w,
      string.format('button action=%s out of bounds: x1=%s x2=%s w=%s', tostring(btn.action), tostring(btn.x1), tostring(btn.x2), tostring(w)))
  end
  for i = 1, #ui.buttons do
    for j = i + 1, #ui.buttons do
      local a, b = ui.buttons[i], ui.buttons[j]
      if a.y == b.y and a.x1 <= b.x2 and b.x1 <= a.x2 then
        error(string.format('overlapping buttons on row %s: %s (%d-%d) vs %s (%d-%d)',
          tostring(a.y), tostring(a.action), a.x1, a.x2, tostring(b.action), b.x1, b.x2))
      end
    end
  end
end

local written = nil
local write_config = function(path, data)
  written = { path = path, data = data }
  return true
end

local config = { feed = { targets = {
  { label = 'Reprocessor A', color = 'RED' },
  { label = 'Reprocessor B', color = 'AQUA' },
} } }

local ui = color_router_ui.new({ config = config, write_config = write_config, log = function() end })

-- The exact size the term.current() fallback gives us when there is no
-- external monitor wired up.
local mon = new_mon(51, 19)
local footer = ui:render(mon, nil, nil, true)
assert_true(type(footer) == 'table' and footer.left and footer.right,
  'the 51x19 computer terminal must render the full page, not the "too small" guard')
assert_eq(#ui.targets, 2, 'both targets must still render on the compact page')
assert_no_overlaps(ui, 51)

local sorter_btn = find_button(ui, 'sorter_open')
local inlet_btn = find_button(ui, 'inlet_open')
assert_true(sorter_btn ~= nil and inlet_btn ~= nil, 'SORTER and ZIEL must both have buttons on the compact page')
assert_true(sorter_btn.y ~= inlet_btn.y, 'on a 51-wide screen SORTER and ZIEL must stack on separate rows, not share one')

-- Enable the chest: its own row must appear too, still within bounds.
local chest_toggle_btn = find_button(ui, 'chest_toggle')
assert_true(chest_toggle_btn ~= nil)
assert_true(ui:handle_touch(chest_toggle_btn.x1, chest_toggle_btn.y) == true)
assert_eq(ui.chest_enabled, true)

ui:render(mon, nil, nil, true)
assert_no_overlaps(ui, 51)
local chest_target_btn = find_button(ui, 'chest_target_open')
assert_true(chest_target_btn ~= nil, 'expected a chest target button once the chest is enabled on the compact page')
assert_true(ui:handle_touch(chest_target_btn.x1, chest_target_btn.y) == true)
assert_eq(ui.mode, 'pick_chest')

-- The picker itself already worked at any width (only the list page needed
-- the compact rework) -- confirm it still renders in bounds at 51 wide.
ui:render(mon, nil, nil, true)
assert_no_overlaps(ui, 51)
local pick_btn = nil
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'pick_chest_choose' and btn.name == 'ender_chest_1' then pick_btn = btn end
end
assert_true(pick_btn ~= nil, 'expected ender_chest_1 as a pickable chest target at 51 wide')
assert_true(ui:handle_touch(pick_btn.x1, pick_btn.y) == true)
assert_eq(ui.chest_target, 'ender_chest_1')

-- Cycle a target's color, then save -- the full flow must work end to end
-- on the compact page exactly like on a wide monitor.
ui:render(mon, nil, nil, true)
assert_no_overlaps(ui, 51)
local next_btn = find_button(ui, 'color_next', 1)
assert_true(next_btn ~= nil, 'expected a color_next button for target 1 on the compact page')
assert_true(ui:handle_touch((next_btn.x1 + next_btn.x2) / 2, next_btn.y) == true)
assert_true(ui.targets[1].color ~= 'RED')

ui:render(mon, nil, nil, true)
assert_no_overlaps(ui, 51)
local save_btn = find_button(ui, 'save')
assert_true(save_btn ~= nil)
assert_true(ui:handle_touch(save_btn.x1, save_btn.y) == true)
assert_true(written ~= nil, 'save must work on the compact page')
assert_eq(written.data.chest.target, 'ender_chest_1')
assert_eq(#written.data.targets, 2)

print('reprocessor_color_router_ui_compact_test.lua: ok')
