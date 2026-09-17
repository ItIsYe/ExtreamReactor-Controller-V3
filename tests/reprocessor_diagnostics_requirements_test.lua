-- Regression coverage for the new "requirements" section on the REPROC
-- Diagnostics page: user request (2026-09-17) -- show, in one place, what
-- the Reprocessor needs (ME-Bridge, Sorter, SORTER-KISTE, optional
-- ZUSATZ-KISTE, Wireless-Modem, Monitor) and whether each is actually
-- connected, instead of having to piece that together from the Registry/
-- Feed displays separately. main.lua's build_requirements() assembles
-- payload.requirements; this test drives nodes/reprocessor/ui_pages.lua's
-- render_diagnostics() directly and checks the rendered rows.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 1000 end

local data_rows = {}
local mux = {}
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.banner = function() end
mux.metric_card = function() end
mux.kpi_strip = function() end
mux.section = function() end
mux.outlined_progress = function() end
mux.card = function() end
mux.data_row = function(mon, x, y, w, opts) data_rows[#data_rows + 1] = opts end
mux.footer_nav = function() return {} end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.reprocessor.ui_pages'] = nil

local support_ui_pages = require('nodes.support.ui_pages')
local ui_pages = require('nodes.reprocessor.ui_pages')
local ui_stub = { getSize = function(mon) return mon.getSize() end }
local pages = ui_pages.new({ ui = ui_stub, support_ui_pages = support_ui_pages })

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

-- exact_prefix: matches "<prefix>:" only, so "SORTER-KISTE" never matches
-- a lookup for "ZUSATZ-KISTE" (both contain "KISTE").
local function find_row(exact_prefix)
  for _, r in ipairs(data_rows) do
    if type(r.label) == 'string' and r.label:sub(1, #exact_prefix + 1) == exact_prefix .. ':' then return r end
  end
  return nil
end

-- Narrow monitor (single-column diagnostics layout, w < 58) so all rows
-- render via the shared bounded list instead of the two-card branch.
local mon = { getSize = function() return 51, 30 end }

-- Case 1: nothing connected -- every requirement row must show FEHLT/WARNING.
data_rows = {}
pages.render_diagnostics(mon, {
  node_id = 'RP-1', status = 'DEGRADED', master_state = 'OK', summary = {}, comms = {}, metrics = {},
  payload = {
    requirements = {
      wireless_modem = false, wired_modem = false, monitor = false, monitor_is_term = false,
      me_bridge = false, sorter = false, sorter_chest_present = false, sorter_chest_name = nil,
      chest_enabled = false,
    },
  },
})
local bridge_row = find_row('ME-BRIDGE')
assert_true(bridge_row ~= nil, 'expected an ME-BRIDGE requirement row')
assert_true(bridge_row.label:find('FEHLT', 1, true) ~= nil, 'ME-BRIDGE must show FEHLT when not bound')
assert_true(bridge_row.status == 'WARNING')

local sorter_row = find_row('SORTER')
assert_true(sorter_row ~= nil and sorter_row.status == 'WARNING', 'expected a WARNING SORTER row')

local sorter_chest_row = find_row('SORTER-KISTE')
assert_true(sorter_chest_row ~= nil and sorter_chest_row.status == 'WARNING', 'expected a WARNING SORTER-KISTE row')

local modem_row = find_row('WIRELESS-MODEM')
assert_true(modem_row ~= nil and modem_row.status == 'WARNING', 'expected a WARNING WIRELESS-MODEM row')

local monitor_row = find_row('MONITOR')
assert_true(monitor_row ~= nil and monitor_row.status == 'WARNING', 'expected a WARNING MONITOR row when absent')

-- ZUSATZ-KISTE is optional -- must NOT appear when chest.enabled is false.
assert_true(find_row('ZUSATZ-KISTE') == nil, 'ZUSATZ-KISTE row must be omitted while the optional chest is disabled')

-- Case 2: everything connected, chest enabled and present -- every row OK,
-- and the bound peripheral names show up in the row text.
data_rows = {}
pages.render_diagnostics(mon, {
  node_id = 'RP-1', status = 'OK', master_state = 'OK', summary = {}, comms = {}, metrics = {},
  payload = {
    requirements = {
      wireless_modem = true, wired_modem = true, monitor = true, monitor_is_term = false,
      me_bridge = true, me_bridge_name = 'meBridge_0',
      sorter = true, sorter_name = 'logistical_sorter_0',
      sorter_chest_present = true, sorter_chest_name = 'minecraft:chest_9',
      chest_enabled = true, chest_present = true, chest_target = 'ender_chest_1',
    },
  },
})
local bridge_row2 = find_row('ME-BRIDGE')
assert_true(bridge_row2.status == 'OK' and bridge_row2.label:find('meBridge_0', 1, true) ~= nil,
  'expected the bound ME-Bridge name in the row text')

local sorter_chest_row2 = find_row('SORTER-KISTE')
assert_true(sorter_chest_row2.status == 'OK' and sorter_chest_row2.label:find('minecraft:chest_9', 1, true) ~= nil)

local zusatz_kiste_row = find_row('ZUSATZ-KISTE')
assert_true(zusatz_kiste_row ~= nil, 'ZUSATZ-KISTE row must appear once the optional chest is enabled')
assert_true(zusatz_kiste_row.status == 'OK' and zusatz_kiste_row.label:find('ender_chest_1', 1, true) ~= nil)

local monitor_row2 = find_row('MONITOR')
assert_true(monitor_row2.status == 'OK')

print('reprocessor_diagnostics_requirements_test.lua: ok')
