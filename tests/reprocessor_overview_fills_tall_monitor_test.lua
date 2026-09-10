-- Regression coverage: render_overview() used to place every block on a
-- fixed row number (banner y=5, cards y=7, section y=22, last data_row
-- y=24) regardless of the monitor's actual height. On any monitor taller
-- than the ~19-row reference layout, everything below row ~26 stayed
-- black -- the UI never used the extra space. Proves the VERARBEITUNGS-
-- LINIEN data_row (the deepest fixed block) now scales its row position
-- with available height, the same way nodes/rt/mockup_pages.lua's
-- render_overview() already did before this fix.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 1000 end

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

local last_data_row_y = nil
local mux = {}
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.banner = function() end
mux.metric_card = function() end
mux.kpi_strip = function() end
mux.section = function() end
mux.outlined_progress = function() end
mux.data_row = function(mon, x, y, w, opts)
  -- Only the VERARBEITUNGSLINIEN row carries a "BUFFER"-less recycle icon
  -- with a label taken from the first buffer id -- but simplest and robust
  -- is to just track the LAST data_row call's y each render, since that is
  -- always the deepest fixed block in overview().
  last_data_row_y = y
end
mux.footer_nav = function() return {} end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.reprocessor.ui_pages'] = nil

local ui_pages = require('nodes.reprocessor.ui_pages')
local ui_stub = { getSize = function(mon) return mon.getSize() end }
local support = { render_log_mode_button = function() end, handle_log_mode_touch = function() return false end }
local pages = ui_pages.new({ ui = ui_stub, support_ui_pages = support })

local model = {
  node_id = 'RP-1', status = 'OK',
  payload = { buffers = { { id = 'chemical_tank_0', stored = 500, capacity = 1000, process_state = 'ok', percent = 50 } },
    feed = { enabled = true, target_count = 1 } },
}

-- Reference-sized monitor (h=30, close to the original ~19-row layout).
local mon_ref = { getSize = function() return 80, 30 end }
pages.render_overview(mon_ref, model)
local y_ref = last_data_row_y
assert_true(y_ref ~= nil, 'expected the VERARBEITUNGSLINIEN row to render on a 80x30 monitor')

-- A much taller monitor (h=60): the deepest block must move further down
-- to fill the extra space, not stay pinned to the same fixed row.
local mon_tall = { getSize = function() return 80, 60 end }
pages.render_overview(mon_tall, model)
local y_tall = last_data_row_y
assert_true(y_tall ~= nil, 'expected the VERARBEITUNGSLINIEN row to render on a 80x60 monitor')
assert_true(y_tall > y_ref,
  string.format('expected the tall monitor to spread content lower (got y_ref=%s y_tall=%s) -- overview() is not filling the extra height',
    tostring(y_ref), tostring(y_tall)))

-- A monitor at or below the reference size must keep the ORIGINAL fixed
-- row (24) -- scale must never shrink below 1.0 and break small monitors.
local mon_small = { getSize = function() return 60, 26 end }
pages.render_overview(mon_small, model)
assert_true(last_data_row_y == 24,
  'a reference-or-smaller monitor must keep the original row 24, got ' .. tostring(last_data_row_y))

print('reprocessor_overview_fills_tall_monitor_test.lua: ok')
