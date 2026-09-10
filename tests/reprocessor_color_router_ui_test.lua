package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for nodes/reprocessor/color_router_ui.lua, the
-- Sorter-color equivalent of the old valve-path router_ui.lua for
-- REPROCESSOR: pick the Sorter and export inlet from the live peripheral
-- list, add/delete a target, cycle its color, and the save/discard
-- roundtrip (save persists {sorter=, export_inlet=, targets=} + applies it
-- to config.feed immediately; discard reverts unsaved edits without
-- touching config.feed).

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = { get = function(name) return name end }

_G.peripheral = {
  isPresent = function(name) return name == 'sorter_0' or name == 'sorter_1' or name == 'chest_0' end,
  getNames = function() return { 'sorter_0', 'sorter_1', 'chest_0' } end,
  getType = function(name)
    if name == 'sorter_0' or name == 'sorter_1' then return 'logisticalSorter' end
    return 'minecraft:chest'
  end,
  getMethods = function(name)
    if name == 'sorter_0' or name == 'sorter_1' then return { 'setDefaultColor', 'getDefaultColor' } end
    return {}
  end,
}

local function new_mon(w, h)
  local cx, cy = 1, 1
  return {
    getSize = function() return w, h end,
    setCursorPos = function(_, x, y) cx, cy = x, y end,
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

local written = nil
local write_config = function(path, data)
  written = { path = path, data = data }
  return true
end

local config = { feed = { sorter = 'sorter_0', export_inlet = 'chest_0', targets = {
  { label = 'Reprocessor A', color = 'RED' },
} } }

local ui = color_router_ui.new({ config = config, write_config = write_config, log = function() end })

local mon = new_mon(80, 30)
local footer = ui:render(mon, nil, nil, true)
assert_true(type(footer) == 'table' and footer.left and footer.right,
  'render() must return footer_nav geometry so ui_router keeps the shared prev/next buttons live')
assert_eq(#ui.targets, 1)
assert_eq(ui.sorter_name, 'sorter_0', 'working copy must load sorter from config.feed')
assert_eq(ui.export_inlet, 'chest_0', 'working copy must load export_inlet from config.feed')
assert_eq(ui.dirty, false, 'freshly loaded working copy must not be dirty')

-- Open the sorter picker, verify only real sorters are listed (not the
-- chest), and pick the other sorter.
local sorter_open_btn = find_button(ui, 'sorter_open')
assert_true(sorter_open_btn ~= nil, 'expected a SORTER button on the list page')
assert_true(ui:handle_touch(sorter_open_btn.x1, sorter_open_btn.y) == true)
assert_eq(ui.mode, 'pick_sorter')

ui:render(mon, nil, nil, true)
assert_true(find_button(ui, 'pick_sorter_choose') ~= nil, 'expected candidate rows in the sorter picker')
for _, btn in ipairs(ui.buttons) do
  assert_true(btn.name ~= 'chest_0', 'the sorter picker must not list a plain chest as a candidate')
end
local pick_sorter1 = nil
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'pick_sorter_choose' and btn.name == 'sorter_1' then pick_sorter1 = btn end
end
assert_true(pick_sorter1 ~= nil, 'expected sorter_1 as a pickable candidate')
assert_true(ui:handle_touch(pick_sorter1.x1, pick_sorter1.y) == true)
assert_eq(ui.mode, 'list', 'choosing a sorter must return to the list page')
assert_eq(ui.sorter_name, 'sorter_1', 'choosing a sorter must update the working copy')
assert_eq(ui.dirty, true, 'choosing a sorter must mark the working copy dirty')

-- Open the export-inlet picker and pick the chest (any peripheral is
-- eligible as an export target, not just detected sorters).
ui:render(mon, nil, nil, true)
local inlet_open_btn = find_button(ui, 'inlet_open')
assert_true(inlet_open_btn ~= nil, 'expected a ZIEL button on the list page')
assert_true(ui:handle_touch(inlet_open_btn.x1, inlet_open_btn.y) == true)
assert_eq(ui.mode, 'pick_inlet')

ui:render(mon, nil, nil, true)
local pick_chest = nil
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'pick_inlet_choose' and btn.name == 'chest_0' then pick_chest = btn end
end
assert_true(pick_chest ~= nil, 'expected chest_0 as a pickable export-inlet candidate')
assert_true(ui:handle_touch(pick_chest.x1, pick_chest.y) == true)
assert_eq(ui.mode, 'list')
assert_eq(ui.export_inlet, 'chest_0', 'choosing an inlet must update the working copy (unchanged value here)')

-- Cancel out of a picker without choosing anything.
ui:render(mon, nil, nil, true)
local sorter_open_btn2 = find_button(ui, 'sorter_open')
assert_true(ui:handle_touch(sorter_open_btn2.x1, sorter_open_btn2.y) == true)
assert_eq(ui.mode, 'pick_sorter')
ui:render(mon, nil, nil, true)
local cancel_btn = find_button(ui, 'pick_cancel')
assert_true(cancel_btn ~= nil)
assert_true(ui:handle_touch(cancel_btn.x1, cancel_btn.y) == true)
assert_eq(ui.mode, 'list', 'cancel must return to the list without changing the selection')
assert_eq(ui.sorter_name, 'sorter_1', 'cancel must not change the previously chosen sorter')

-- Cycle target 1's color forward from RED.
ui:render(mon, nil, nil, true)
local next_btn = find_button(ui, 'color_next', 1)
assert_true(next_btn ~= nil, 'expected a color_next button for target 1')
assert_true(ui:handle_touch((next_btn.x1 + next_btn.x2) / 2, next_btn.y) == true)
assert_true(ui.targets[1].color ~= 'RED', 'color_next must advance past RED')

-- Add a second target.
ui:render(mon, nil, nil, true)
local add_btn = find_button(ui, 'add')
assert_true(add_btn ~= nil)
assert_true(ui:handle_touch(add_btn.x1, add_btn.y) == true)
assert_eq(#ui.targets, 2, 'add must append a new target')

-- Nothing must be persisted to config.feed before SAVE.
assert_eq(#config.feed.targets, 1, 'unsaved edits must not leak into config.feed.targets')
assert_eq(config.feed.sorter, 'sorter_0', 'unsaved sorter change must not leak into config.feed')

-- Save.
ui:render(mon, nil, nil, true)
local save_btn = find_button(ui, 'save')
assert_true(save_btn ~= nil)
assert_true(ui:handle_touch(save_btn.x1, save_btn.y) == true)
assert_eq(ui.dirty, false, 'save must clear the dirty flag')
assert_true(written ~= nil, 'save must call write_config')
assert_eq(written.data.sorter, 'sorter_1', 'the persisted file must contain the chosen sorter')
assert_eq(written.data.export_inlet, 'chest_0', 'the persisted file must contain the chosen export inlet')
assert_eq(#written.data.targets, 2, 'the persisted file must contain both targets')
assert_eq(#config.feed.targets, 2, 'save must apply the working copy to config.feed.targets immediately')
assert_eq(config.feed.sorter, 'sorter_1', 'save must apply the chosen sorter to config.feed immediately')

-- Discard after a further edit must revert to the last-saved state.
ui:render(mon, nil, nil, true)
local del_btn = find_button(ui, 'delete', 1)
assert_true(del_btn ~= nil)
assert_true(ui:handle_touch(del_btn.x1, del_btn.y) == true)
assert_eq(#ui.targets, 1, 'delete must remove the target from the working copy')
assert_eq(ui.dirty, true)

ui:render(mon, nil, nil, true)
local discard_btn = find_button(ui, 'discard')
assert_true(discard_btn ~= nil)
assert_true(ui:handle_touch(discard_btn.x1, discard_btn.y) == true)
assert_eq(#ui.targets, 2, 'discard must reload the working copy from config.feed.targets (last saved state)')
assert_eq(ui.dirty, false)
assert_eq(#config.feed.targets, 2, 'discard must not touch config.feed.targets')

-- A too-small monitor must render the size guard, not crash or draw
-- overlapping buttons.
local tiny_mon = new_mon(30, 8)
local tiny_footer = ui:render(tiny_mon, nil, nil, true)
assert_true(type(tiny_footer) == 'table', 'even the size-guard path must still return footer_nav geometry')
assert_eq(#ui.buttons, 0, 'no row/action buttons should be built when the monitor is below the minimum size')

print('reprocessor_color_router_ui_test.lua: ok')
