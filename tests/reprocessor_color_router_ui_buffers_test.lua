package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for the PUFFER picker added to nodes/reprocessor/
-- color_router_ui.lua. User report (2026-09-17, screenshots): "Keine
-- Buffer gefunden -- Discovery/Binding pruefen" -- the reprocessor's
-- buffer discovery already supports item-inventory peripherals (list()+
-- size(), not just chemical/fluid tanks -- see main.lua's
-- is_buffer_method_set()), the actual problem was the hardcoded default
-- config.buffers = {"chemical_tank_0"} not matching the operator's real
-- peripheral name. This test drives the new "buffers"/"pick_buffer" UI
-- modes: add a buffer from a live candidate list, delete one, and confirm
-- SPEICHERN persists config.buffers via a dedicated write_buffers()
-- callback (config.buffers is a separate top-level config field, not part
-- of reproc_targets.lua/config.feed).

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = { get = function(name) return name end }

_G.peripheral = {
  isPresent = function() return false end,
  getNames = function() return {} end,
  getType = function() return nil end,
  getMethods = function() return {} end,
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

local written_buffers = nil
local function write_buffers(list)
  written_buffers = list
  return true
end

local candidates = { 'minecraft:barrel_3', 'minecraft:barrel_7' }
local function get_buffer_candidates() return candidates end

local config = { feed = { sorter = 'sorter_0', targets = {} }, buffers = { 'minecraft:barrel_3' } }
local ui = color_router_ui.new({
  config = config,
  write_config = function() return true end,
  get_buffer_candidates = get_buffer_candidates,
  write_buffers = write_buffers,
  log = function() end,
})

local mon = new_mon(80, 30)
ui:render(mon, nil, nil, true)
assert_eq(#ui.buffers, 1, 'working copy must load config.buffers')
assert_eq(ui.buffers[1], 'minecraft:barrel_3')

-- Open the PUFFER sub-page from the main list.
local buffers_open_btn = find_button(ui, 'buffers_open')
assert_true(buffers_open_btn ~= nil, 'expected a PUFFER button on the list page')
assert_true(ui:handle_touch(buffers_open_btn.x1, buffers_open_btn.y) == true)
assert_eq(ui.mode, 'buffers')

ui:render(mon, nil, nil, true)
assert_true(find_button(ui, 'buffer_delete', 1) ~= nil, 'expected a delete button for the existing buffer')

-- Open the buffer picker, verify only the un-added candidate is useful to
-- add (both are listed, but adding the already-present one must not
-- duplicate it), and pick the new one.
local add_open_btn = find_button(ui, 'buffer_add_open')
assert_true(add_open_btn ~= nil, 'expected a + HINZUFUEGEN button on the buffers sub-page')
assert_true(ui:handle_touch(add_open_btn.x1, add_open_btn.y) == true)
assert_eq(ui.mode, 'pick_buffer')

ui:render(mon, nil, nil, true)
local pick_new = nil
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'pick_buffer_choose' and btn.name == 'minecraft:barrel_7' then pick_new = btn end
end
assert_true(pick_new ~= nil, 'expected the not-yet-added candidate to be pickable')
assert_true(ui:handle_touch(pick_new.x1, pick_new.y) == true)
-- Cancelling out of a picker opened from "buffers" must return to
-- "buffers", not the main "list" page.
assert_eq(ui.mode, 'buffers', 'choosing a buffer must return to the buffers sub-page it was opened from')
assert_eq(#ui.buffers, 2, 'the new buffer must be appended')
assert_eq(ui.dirty, true, 'adding a buffer must mark the working copy dirty')

-- Picking an already-added candidate again must not create a duplicate.
ui:render(mon, nil, nil, true)
local add_open_btn2 = find_button(ui, 'buffer_add_open')
ui:handle_touch(add_open_btn2.x1, add_open_btn2.y)
ui:render(mon, nil, nil, true)
local pick_existing = nil
for _, btn in ipairs(ui.buttons) do
  if btn.action == 'pick_buffer_choose' and btn.name == 'minecraft:barrel_3' then pick_existing = btn end
end
assert_true(pick_existing ~= nil)
ui:handle_touch(pick_existing.x1, pick_existing.y)
assert_eq(#ui.buffers, 2, 'picking an already-present buffer must not duplicate it')

-- Cancel-out-of-picker (ABBRECHEN) must also return to "buffers".
ui:render(mon, nil, nil, true)
local add_open_btn3 = find_button(ui, 'buffer_add_open')
ui:handle_touch(add_open_btn3.x1, add_open_btn3.y)
ui:render(mon, nil, nil, true)
local cancel_btn = find_button(ui, 'pick_cancel')
assert_true(cancel_btn ~= nil)
ui:handle_touch(cancel_btn.x1, cancel_btn.y)
assert_eq(ui.mode, 'buffers', 'ABBRECHEN from the buffer picker must return to the buffers sub-page')

-- Delete the original buffer, leaving only the newly added one.
ui:render(mon, nil, nil, true)
local del_btn = find_button(ui, 'buffer_delete', 1)
assert_true(del_btn ~= nil)
ui:handle_touch(del_btn.x1, del_btn.y)
assert_eq(#ui.buffers, 1, 'delete must remove the buffer from the working copy')
assert_eq(ui.buffers[1], 'minecraft:barrel_7')

-- Only buffers[1] is the real ME-Bridge export target (feed_router.lua's
-- feed_one()) -- the buffers sub-page must mark entry 1 distinctly so the
-- operator can tell it apart from purely cosmetic capacity-display entries.
do
  local writes = {}
  local capture_mon = new_mon(80, 30)
  capture_mon.write = function(text) writes[#writes + 1] = tostring(text) end
  ui:render(capture_mon, nil, nil, true)
  local found = false
  for _, w in ipairs(writes) do
    if w:find("EXPORT%-ZIEL") then found = true end
  end
  assert_true(found, 'expected buffer entry 1 to be marked as the export target on the buffers sub-page')
end

-- Back to the list, then SAVE -- must persist buffers via write_buffers()
-- (a SEPARATE top-level config field, not part of reproc_targets.lua).
local back_btn = find_button(ui, 'buffers_back')
assert_true(back_btn ~= nil)
ui:handle_touch(back_btn.x1, back_btn.y)
assert_eq(ui.mode, 'list')

ui:render(mon, nil, nil, true)
local save_btn = find_button(ui, 'save')
assert_true(save_btn ~= nil)
ui:handle_touch(save_btn.x1, save_btn.y)
assert_true(written_buffers ~= nil, 'save must call write_buffers()')
assert_eq(#written_buffers, 1)
assert_eq(written_buffers[1], 'minecraft:barrel_7')
assert_eq(#config.buffers, 1, 'save must apply the working copy to config.buffers immediately')
assert_eq(config.buffers[1], 'minecraft:barrel_7')

print('reprocessor_color_router_ui_buffers_test.lua: ok')
