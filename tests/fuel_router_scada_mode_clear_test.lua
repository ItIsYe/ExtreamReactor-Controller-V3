package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test: switching between the FUEL Router's internal modes
-- (list/edit/path/learn/chest_pick) must fully clear the screen once per
-- mode change. Before this fix, draw_list()/draw_edit()/draw_path()/etc.
-- never called mux.clear() themselves and relied entirely on the caller's
-- should_clear flag -- which is only true when switching between the 4
-- top-level pages (Overview/Details/Diagnostics/Router), never for these
-- internal mode changes. Stale content from the previous mode (e.g. the
-- list's SPEICHERN/VERWERFEN buttons at y=33) stayed on screen next to the
-- new mode's own buttons (e.g. edit's FERTIG/LOESCHEN/ABBRECHEN at y=31),
-- looking like overlapping buttons (user report 2026-09-14).

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
}
_G.redstone = { setOutput = function() end }

local clear_calls = 0
local mux = require('core.mockup_ui')
local real_clear = mux.clear
mux.clear = function(...)
  clear_calls = clear_calls + 1
  return real_clear(...)
end

local redstone_router = require('nodes.fuel.redstone_router')
local router_ui = require('nodes.fuel.router_ui')

local comms = { get_peers = function() return {} end }
local reactors = {
  { reactor_id = 'R1', label = 'Reactor1', path = { 'VALVE-1' }, request_below = 0.25, fill_amount = 64, min_in_me = 32 },
}
local rs = redstone_router.new({
  config = { logistics = { redstone_tree = {} } },
  comms = comms, log = function() end, warn_once = function() end,
})
rs:refresh()

local config = { logistics = { reactors = reactors } }
local page = router_ui.new({
  config = config,
  redstone_router = rs,
  get_reactors = function() return {} end,
  log = function() end,
})

local mon = { getSize = function() return 82, 40 end }
local ui_stub = { getSize = function(target) return target.getSize() end }

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

-- 1) First render (list mode, should_clear=true) always clears at least
--    once -- initial paint. (May clear twice: once via the caller's
--    should_clear flag, once via the mode-entry clear below -- harmless
--    redundancy only on the very first render, not the bug this test
--    guards against.)
page._ui.mode = 'list'
clear_calls = 0
page:render(mon, ui_stub, nil, true)
assert_true(clear_calls >= 1, 'first render must clear at least once, got ' .. clear_calls)

-- 2) A second render of the SAME mode (list, e.g. a routine redraw with
--    should_clear=false, as happens every tick while staying on the
--    Router page) must NOT clear again -- that would defeat the whole
--    point of should_clear-driven partial redraws.
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 0, 'same-mode re-render must not clear, got ' .. clear_calls)

-- 3) Switching to edit mode (e.g. tapping a reactor's EDIT button) must
--    clear exactly once, even though should_clear is false (internal mode
--    change, not a top-level page switch).
page._ui.mode = 'edit'
page._ui.editing = reactors[1]
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 1, 'list -> edit mode switch must clear once, got ' .. clear_calls)

-- 4) Re-rendering edit mode again (e.g. a stepper value changed) must not
--    clear again.
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 0, 'same-mode (edit) re-render must not clear, got ' .. clear_calls)

-- 5) Switching to path mode (tapping "ROUTE EINRICHTEN") must clear once.
page._ui.mode = 'path'
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 1, 'edit -> path mode switch must clear once, got ' .. clear_calls)

-- 6) Switching back to list mode must clear once (this is exactly the
--    "old SPEICHERN/VERWERFEN next to new FERTIG/ABBRECHEN" scenario).
page._ui.mode = 'list'
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 1, 'path -> list mode switch must clear once, got ' .. clear_calls)

-- 7) learn and chest_pick modes must each clear once on entry too.
page._ui.mode = 'learn'
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 1, 'list -> learn mode switch must clear once, got ' .. clear_calls)

page._ui.mode = 'chest_pick'
clear_calls = 0
page:render(mon, ui_stub, nil, false)
assert_true(clear_calls == 1, 'learn -> chest_pick mode switch must clear once, got ' .. clear_calls)

mux.clear = real_clear
print('fuel_router_scada_mode_clear_test.lua: ok')
