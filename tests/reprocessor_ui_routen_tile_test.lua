-- Regression coverage for the Reprocessor Overview's FEEDING/ZIELE tiles
-- (2026-09-17 rebuild): FEEDING shows the AN/AUS toggle state directly,
-- ZIELE shows the configured target count -- no more "active/total" ratio
-- (feed_router.lua has no per-route active concept, just a global enabled
-- switch), so there is nothing left to compute wrong here, but the tiles
-- must still read the right fields from get_summary()'s actual shape
-- (enabled/target_count), not fields copied from the Fuel UI that
-- feed_router.lua never produces.

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

local function find_card(cards, label)
  for _, c in ipairs(cards) do
    if c.label == label then return c end
  end
  return nil
end

-- Fall 1: Feeding aktiv, 3 konfigurierte Targets.
metric_cards = {}
pages.render_overview(mon, {
  node_id = 'RP-1', status = 'OK',
  payload = { feed = { enabled = true, target_count = 3 }, requirements = { me_bridge = true, sorter = true, sorter_chest_present = true } },
})
local feeding1 = find_card(metric_cards, 'FEEDING')
if not feeding1 or feeding1.value ~= 'AN' then
  error("expected FEEDING tile to show 'AN' when enabled, got " .. tostring(feeding1 and feeding1.value))
end
local ziele1 = find_card(metric_cards, 'ZIELE')
if not ziele1 or ziele1.value ~= '3' then
  error("expected ZIELE tile to show '3' for 3 configured targets, got " .. tostring(ziele1 and ziele1.value))
end

-- Fall 2: Feeding deaktiviert -- ZIELE bleibt trotzdem die Gesamtzahl
-- sichtbar (keine "0/3"-Verwechslung mehr).
metric_cards = {}
pages.render_overview(mon, {
  node_id = 'RP-1', status = 'OK',
  payload = { feed = { enabled = false, target_count = 3 }, requirements = {} },
})
local feeding2 = find_card(metric_cards, 'FEEDING')
if not feeding2 or feeding2.value ~= 'AUS' then
  error("expected FEEDING tile to show 'AUS' when disabled, got " .. tostring(feeding2 and feeding2.value))
end
local ziele2 = find_card(metric_cards, 'ZIELE')
if not ziele2 or ziele2.value ~= '3' then
  error("expected ZIELE tile to still show '3' while feeding is disabled, got " .. tostring(ziele2 and ziele2.value))
end

print('reprocessor_ui_routen_tile_test.lua: ok')
