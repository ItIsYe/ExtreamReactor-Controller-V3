-- Die ROUTEN-Kachel auf der Reprocessor-Overview suchte nach
-- feed.active_routes/feed.active/feed.routes_active und
-- feed.total_routes/feed.total/feed.routes_total -- Feldnamen, die aus der
-- Fuel-UI kopiert wurden. feed_router.lua:get_summary() liefert aber nur
-- enabled/target_count -- keines dieser Felder existiert, also zeigte die
-- Kachel unabhaengig vom echten Zustand immer "0/0" an.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 1000 end

local metric_cards = {}
local mux = {}
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.banner = function() end
mux.metric_card = function(mon, x, y, w, h, opts) metric_cards[#metric_cards + 1] = opts end
mux.kpi_strip = function() end
mux.section = function() end
mux.outlined_progress = function() end
mux.data_row = function() end
mux.footer_nav = function() return {} end
package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.reprocessor.ui_pages'] = nil

local ui_pages = require('nodes.reprocessor.ui_pages')
local ui_stub = { getSize = function(mon) return mon.getSize() end }
local support = { render_log_mode_button = function() end, handle_log_mode_touch = function() return false end }
local pages = ui_pages.new({ ui = ui_stub, support_ui_pages = support })

local mon = { getSize = function() return 70, 24 end }

local function find_routen(cards)
  for _, c in ipairs(cards) do
    if c.label == 'ROUTEN' then return c end
  end
  return nil
end

-- Fall 1: Feeding aktiv, 3 konfigurierte Targets -- muss "3/3" zeigen, nicht "0/0".
metric_cards = {}
pages.render_overview(mon, {
  node_id = 'RP-1', status = 'OK',
  payload = { buffers = {}, feed = { enabled = true, target_count = 3 } },
})
local tile1 = find_routen(metric_cards)
if not tile1 then error('expected a ROUTEN tile to be rendered') end
if tile1.value ~= '3/3' then
  error("expected ROUTEN tile to show '3/3' for an enabled router with 3 targets, got " .. tostring(tile1.value))
end

-- Fall 2: Feeding deaktiviert -- 0 aktive Routen, aber die konfigurierten
-- Targets bleiben als Gesamtzahl sichtbar ("0/3"), nicht "0/0".
metric_cards = {}
pages.render_overview(mon, {
  node_id = 'RP-1', status = 'OK',
  payload = { buffers = {}, feed = { enabled = false, target_count = 3 } },
})
local tile2 = find_routen(metric_cards)
if not tile2 or tile2.value ~= '0/3' then
  error("expected ROUTEN tile to show '0/3' for a disabled router with 3 configured targets, got " .. tostring(tile2 and tile2.value))
end

print('reprocessor_ui_routen_tile_test.lua: ok')
