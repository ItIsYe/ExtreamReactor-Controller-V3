-- A low/not-full ENERGY storage level is expected operating behavior, not
-- a fault: nodes/energy/ui_pages.lua's overview banner/tiles must cap the
-- status at WARNING even far below the old 15% "critical" threshold --
-- never EMERGENCY (shown as a red fault/"Störung").

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 1000 end

local banners = {}
local metric_cards = {}
local mux = {}
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.banner = function(mon, x, y, w, text, status, icon) banners[#banners + 1] = { text = text, status = status } end
mux.metric_card = function(mon, x, y, w, h, opts) metric_cards[#metric_cards + 1] = opts end
mux.kpi_strip = function() end
mux.section = function() end
mux.card = function() end
mux.data_row = function() end
mux.outlined_progress = function() end
mux.footer_nav = function() return {} end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.support.ui_pages'] = { render_log_mode_button = function() end, handle_log_mode_touch = function() return false end }
package.loaded['nodes.energy.ui_pages'] = nil

local ui_pages = require('nodes.energy.ui_pages')
local ui_stub = { getSize = function(mon) return mon.getSize() end }
local ui_router = { paginate = function() return { page = 1, start_index = 1, end_index = 0 } end }
local pages = ui_pages.new({ ui = ui_stub, colors = { get = function() return 1 end }, ui_router = ui_router, ui_state = {} })

local mon = { getSize = function() return 70, 24 end }

-- 1% full: far below the old 15% "STORAGE CRITICAL"/EMERGENCY threshold.
local model = {
  node_id = 'EN-1',
  total = { percent = 0.01, input = 10, output = 10, stored = 10, capacity = 1000 },
  matrices = {},
}

pages.render_overview(mon, model)

if #banners == 0 then error('expected the storage banner to render') end
local banner = banners[1]
if banner.status == 'EMERGENCY' then
  error('near-empty (not full) storage must not render as EMERGENCY, got status=' .. tostring(banner.status))
end
if banner.status ~= 'WARNING' then
  error('expected the low-storage banner to be WARNING, got: ' .. tostring(banner.status))
end

for _, card in ipairs(metric_cards) do
  if card.label == 'ENERGIE' and card.status == 'EMERGENCY' then
    error('ENERGIE metric card must not render as EMERGENCY for a low/not-full store')
  end
end

print('energy_low_storage_never_emergency_test.lua: ok')
