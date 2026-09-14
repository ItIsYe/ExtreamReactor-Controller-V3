package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (user report 2026-09-14, screenshot): overview() only
-- clears the screen on the very first render (should_clear -- see
-- draw_header()), not on every tick. When a reactor slot's text SHRINKS
-- between two renders without a clear in between -- e.g. "NICHT
-- KONFIGURIERT" (19 chars) becoming "Reaktor 4" (9 chars) once the
-- reactor gets configured -- mux.fit() only truncates long text, it never
-- pads short text, so the old text's tail kept showing: "Reaktor
-- 4NFIGURIERT". Same for the right-aligned status text (position depends
-- on its own length) and the HINWEIS note line. draw_reactor_slot() now
-- pads every variable-length write to a fixed slot width.

_G.peripheral = {
  find = function() return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
  getNames = function() return {} end,
}
_G.redstone = { setOutput = function() end }

-- Real core/mockup_ui.lua + shared/colors.lua against a full cell-buffer
-- monitor mock, so the actually-rendered characters at each position can
-- be inspected (not just that some render call happened).
local W, H = 82, 40
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
    clear = function() for y = 1, H do for x = 1, W do cells[y][x] = ' ' end end end,
    row = function(y) return table.concat(cells[y]) end,
  }
end

local scada_layout = require('nodes.fuel.scada_layout')
local ui = {}
scada_layout.attach(ui, {})

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

local model = {
  node_id = 'FUEL-1', status = 'OK', master_state = 'OK',
  summary = { total = 1, missing = 0 }, local_alerts = {},
  last_scan = 'now', last_command = 'none',
  ui_diagnostics = { error_count = 0, frames_committed = 1, frames_requested = 1, frames_skipped = 0, pointer_events_received = 0, model_builds = 1 },
  view_state = { code = 'READY', severity = 'OK', title = 'Bereit', detail = 'Alles bereit' },
  payload = {
    reserve = 10000, minimum_reserve = 2000,
    valve_summary = { total = 1, offline = 0, stale = 0 },
    logistics = {
      enabled = true, bridge = 'meBridge_0', export_chest = 'chest_3',
      reactors = {}, -- slot 1 starts unconfigured
      fuel_data_summary = { fresh = 0, stale = 0, missing = 0 },
      fuel_families = {},
    },
  },
}

local mon = new_mon()

-- 1) First render: slot 1 unconfigured -- "01  NICHT KONFIGURIERT".
ui.render_overview(mon, model, true)
assert_true(mon.row(14):find('NICHT KONFIGURIERT', 1, true) ~= nil,
  'expected the unconfigured placeholder on row 14')

-- 2) Reactor becomes configured with a SHORT label, re-render WITHOUT
--    clearing (should_clear=false -- exactly what happens in-game when a
--    reactor's state changes while the Overview page is already showing,
--    no top-level page switch involved).
model.payload.logistics.reactors = {
  { reactor_id = 'R1', label = 'Reaktor 2', fuel_pct = 61, fuel_data_state = 'FRESH',
    fuel_age_s = 1, delivery_state = 'READY', path = { 'VALVE-1', 'VALVE-2', 'VALVE-3' } },
}
ui.render_overview(mon, model, false)
-- Slot 1 (reactor R1, now configured) is the LEFT column only, x=2..40 --
-- slot 7 shares row 14 in the RIGHT column (x=43..) and legitimately still
-- says "NICHT KONFIGURIERT" (nothing configured there), so restrict the
-- check to slot 1's own cell range.
local left_col = mon.row(14):sub(2, 41)
assert_true(left_col:find('Reaktor 2', 1, true) ~= nil, 'expected the new short label on row 14, got: ' .. left_col)
assert_true(left_col:find('NFIGURIERT', 1, true) == nil,
  'old "NICHT KONFIGURIERT" tail must not survive next to the new label, got: ' .. left_col)
assert_true(left_col:find('KONFIGURIERT', 1, true) == nil,
  'old placeholder text must be fully cleared from row 14, got: ' .. left_col)

print('fuel_scada_overview_reactor_slot_ghosting_test.lua: ok')
