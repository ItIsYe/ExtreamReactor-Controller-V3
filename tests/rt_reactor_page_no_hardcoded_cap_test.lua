-- render_reactors() deckelte die REAKTOREN-Seite bislang hart auf 2
-- Reaktoren ("GESAMT x/2", nur die ersten 2 Karten gerendert), obwohl ein
-- RT-Knoten laut reactor_control.lua (controlReactorsIndividually) mehr als
-- 2 Reaktoren verwalten kann. Muss wie die Turbinen-Seite (GESAMT = reine
-- Gesamtzahl, Abbruch nur durch verfuegbaren Bildschirmplatz) funktionieren.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local metric_cards = {}
local cards = {}

local mux = {}
mux.clear = function() end
mux.header = function() end
mux.status_dot = function() end
mux.metric_card = function(mon, x, y, w, h, item) metric_cards[#metric_cards + 1] = item end
mux.kpi_strip = function(mon, x, y, w, items)
  for _, item in ipairs(items) do metric_cards[#metric_cards + 1] = item end
end
mux.warning_box = function() end
mux.card = function(mon, x, y, w, h, item) cards[#cards + 1] = item end
mux.outlined_progress = function() end
mux.footer_nav = function() return {} end

package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.rt.mockup_pages'] = nil
local mockup_pages = require('nodes.rt.mockup_pages')

local mon = { getSize = function() return 60, 40 end }
local model = {
  node_id = 'RT-1',
  master_state = 'OK',
  capacity_ready = true,
  snapshot = { snapshot = {
    reactors = {
      { id = 'R1', active = true, temperature = 500, rods = 40, steam_production = 100 },
      { id = 'R2', active = true, temperature = 520, rods = 42, steam_production = 110 },
      { id = 'R3', active = true, temperature = 510, rods = 41, steam_production = 105 },
    },
    avg_temp = 510, steam_amount = 1000,
  }},
}

mockup_pages.render_reactors(mon, model)

local total_kpi = nil
for _, item in ipairs(metric_cards) do
  if item.label == 'GESAMT' then total_kpi = item end
end
if not total_kpi then error('expected a GESAMT metric card') end
if total_kpi.value ~= '3' then
  error("expected GESAMT to show the real total '3', got " .. tostring(total_kpi.value))
end

if #cards ~= 3 then
  error('expected all 3 reactor cards to render, got ' .. tostring(#cards))
end
local seen = {}
for _, c in ipairs(cards) do seen[c.title] = true end
for _, id in ipairs({ 'R1', 'R2', 'R3' }) do
  local found = false
  for title in pairs(seen) do
    if title:find(id, 1, true) then found = true end
  end
  if not found then error('expected a rendered card for reactor ' .. id) end
end

print('rt_reactor_page_no_hardcoded_cap_test.lua: ok')
