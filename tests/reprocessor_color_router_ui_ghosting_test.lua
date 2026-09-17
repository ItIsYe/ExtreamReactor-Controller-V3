package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (screenshot 2026-09-17, right after fixing the
-- get_color_router forward-reference crash -- see tests/reprocessor_get_
-- color_router_ui_ghosting_test.lua's sibling reprocessor_get_color_
-- router_forward_decl_test.lua): once the Router page actually rendered,
-- adding the first target left visible leftovers of the empty-state
-- warning_box text ("Keine Reprocessoren konfiguriert." / "+ HINZUFUEGEN
-- antippen.") mixed in with the newly drawn target row.
--
-- Root cause: render()'s "should_clear" parameter only reflects a PAGE
-- transition (ui_router.lua switching pages) -- it stays false across
-- in-page redraws while the operator edits the target list. But the
-- empty-state warning_box and the per-target row loop occupy the SAME
-- screen rows with very different content, and core/mockup_ui.lua's
-- M.text() writes literal text with no padding to a fixed width (unlike
-- M.button(), which does pad). Going from 0 targets to 1+ without a full
-- clear left the warning box's text sitting under/around the new row's
-- unpadded label.
--
-- Fix: render() now clears whenever a layout-affecting signature
-- (#targets/mode/chest_enabled) changes since the last render, not only on
-- a page transition.

package.loaded['core.mockup_ui'] = nil
package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.color_router_ui'] = nil
package.loaded['shared.colors'] = {
  get = function(name)
    -- core/mockup_ui.lua only ever uses these as opaque tokens passed
    -- straight through to setTextColor/setBackgroundColor -- the mock
    -- monitor below ignores color entirely, only tracking written glyphs.
    return name
  end,
}

_G.peripheral = {
  isPresent = function() return true end,
  getNames = function() return {} end,
  getType = function() return nil end,
  getMethods = function() return {} end,
}

-- Real core/mockup_ui.lua against a full cell-buffer monitor mock, so the
-- actually-rendered characters at each position can be inspected -- not
-- just that some render call happened (matches tests/fuel_scada_overview_
-- reactor_slot_ghosting_test.lua's pattern for the same bug class).
local W, H = 80, 30
local function new_mon()
  local cells = {}
  for y = 1, H do cells[y] = {}; for x = 1, W do cells[y][x] = ' ' end end
  local cx, cy = 1, 1
  return {
    getSize = function() return W, H end,
    setCursorPos = function(x, y) cx, cy = x, y end,
    setTextColor = function() end, setBackgroundColor = function() end,
    write = function(s)
      s = tostring(s or '')
      for i = 1, #s do
        if cx + i - 1 >= 1 and cx + i - 1 <= W and cy >= 1 and cy <= H then
          cells[cy][cx + i - 1] = s:sub(i, i)
        end
      end
    end,
    row = function(y) return table.concat(cells[y]) end,
    full_screen = function()
      local rows = {}
      for y = 1, H do rows[y] = table.concat(cells[y]) end
      return table.concat(rows, '\n')
    end,
  }
end

local color_router_ui = require('nodes.reprocessor.color_router_ui')

local write_config = function() return true end
local config = { feed = { sorter = nil, export_inlet = nil, targets = {} } }
local ui = color_router_ui.new({ config = config, write_config = write_config, log = function() end })

local mon = new_mon()

-- 1) First render (page transition, should_clear=true): 0 targets ->
--    the empty-state warning_box is shown.
ui:render(mon, nil, nil, true)
local screen_before = mon.full_screen()
if not screen_before:find('Keine Reprocessoren konfiguriert', 1, true) then
  error('expected the empty-state warning box on the initial render')
end

-- 2) Add a target (simulating the operator tapping "+ HINZUFUEGEN"), then
--    render again as an IN-PAGE redraw (should_clear=false) -- exactly
--    what ui_router.lua does for any redraw that isn't a page switch.
ui.targets[1] = { label = 'Reprocessor 1', color = 'BLACK' }
ui:render(mon, nil, nil, false)

local screen_after = mon.full_screen()
if screen_after:find('konfiguriert', 1, true) then
  error('leftover warning-box text ("konfiguriert") must not survive the empty -> populated transition, got:\n' .. screen_after)
end
if screen_after:find('antippen', 1, true) then
  error('leftover warning-box text ("antippen") must not survive the empty -> populated transition, got:\n' .. screen_after)
end
if not screen_after:find('Reprocessor 1', 1, true) then
  error('expected the new target row to actually be drawn')
end

-- 3) The reverse transition (populated -> empty, e.g. deleting the last
--    target) must equally leave no stale row text behind.
ui.targets[1] = nil
ui:render(mon, nil, nil, false)
local screen_final = mon.full_screen()
if screen_final:find('Reprocessor 1', 1, true) then
  error('leftover target row text must not survive the populated -> empty transition, got:\n' .. screen_final)
end
if not screen_final:find('Keine Reprocessoren konfiguriert', 1, true) then
  error('expected the empty-state warning box to reappear once the last target is removed')
end

print('reprocessor_color_router_ui_ghosting_test.lua: ok')
