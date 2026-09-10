package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for nodes/reprocessor/color_router_ui.lua, the
-- Sorter-color equivalent of the old valve-path router_ui.lua for
-- REPROCESSOR: add/delete a target, cycle its color, and the save/discard
-- roundtrip (save persists + applies to config.feed.targets immediately;
-- discard reverts unsaved edits without touching config.feed.targets).

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = { get = function(name) return name end }

_G.peripheral = { isPresent = function() return false end }

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

local config = { feed = { targets = {
  { label = 'Reprocessor A', color = 'RED' },
} } }

local ui = color_router_ui.new({ config = config, write_config = write_config, log = function() end })

local mon = new_mon(80, 30)
local footer = ui:render(mon, nil, nil, true)
assert_true(type(footer) == 'table' and footer.left and footer.right,
  'render() must return footer_nav geometry so ui_router keeps the shared prev/next buttons live')
assert_eq(#ui.targets, 1)
assert_eq(ui.dirty, false, 'freshly loaded working copy must not be dirty')

-- Cycle target 1's color forward from RED.
local next_btn = find_button(ui, 'color_next', 1)
assert_true(next_btn ~= nil, 'expected a color_next button for target 1')
assert_true(ui:handle_touch((next_btn.x1 + next_btn.x2) / 2, next_btn.y) == true)
assert_true(ui.targets[1].color ~= 'RED', 'color_next must advance past RED')
assert_eq(ui.dirty, true, 'an edit must mark the working copy dirty')

-- Add a second target.
ui:render(mon, nil, nil, true)
local add_btn = find_button(ui, 'add')
assert_true(add_btn ~= nil)
assert_true(ui:handle_touch(add_btn.x1, add_btn.y) == true)
assert_eq(#ui.targets, 2, 'add must append a new target')

-- Nothing must be persisted to config.feed.targets before SAVE.
assert_eq(#config.feed.targets, 1, 'unsaved edits must not leak into config.feed.targets')

-- Save.
ui:render(mon, nil, nil, true)
local save_btn = find_button(ui, 'save')
assert_true(save_btn ~= nil)
assert_true(ui:handle_touch(save_btn.x1, save_btn.y) == true)
assert_eq(ui.dirty, false, 'save must clear the dirty flag')
assert_true(written ~= nil, 'save must call write_config')
assert_eq(#written.data, 2, 'the persisted file must contain both targets')
assert_eq(#config.feed.targets, 2, 'save must apply the working copy to config.feed.targets immediately')

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
