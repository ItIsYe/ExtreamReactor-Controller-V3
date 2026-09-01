-- ui/resources.lua rechnete mit einem komplett leeren Model (model.fuel/
-- .water bleiben in ui_controller.lua bewusst {} -- diese Aggregation ist
-- eine bekannte, nicht implementierte Luecke) trotzdem seine normalen
-- Fuel/Water-Badges aus. water_ratio wird dabei 0/0 -> 0, was einen aktiv
-- falschen "EMERGENCY"-Badge fuer den Water Loop anzeigte, obwohl schlicht
-- keine Daten verkabelt sind. Muss stattdessen einen ehrlichen
-- "keine Daten"-Hinweis zeigen und dabei nicht in die irrefuehrende
-- Berechnung laufen.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.colors = _G.colors or {
  white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16, lime = 32,
  pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
  brown = 4096, green = 8192, red = 16384, black = 32768,
}

local calls = {}
local fake_ui = {
  getSize = function() return 40, 30 end,
  panel = function() end,
  text = function(mon, x, y, text) calls[#calls + 1] = { fn = 'text', text = text } end,
  badge = function(mon, x, y, text, status) calls[#calls + 1] = { fn = 'badge', text = text, status = status } end,
  bigNumber = function(mon, x, y, label, value, unit, status) calls[#calls + 1] = { fn = 'bigNumber', label = label, status = status } end,
  progress = function() calls[#calls + 1] = { fn = 'progress' } end,
  list = function() calls[#calls + 1] = { fn = 'list' } end,
  rightText = function() end,
}
package.loaded['core.ui'] = fake_ui
package.loaded['master.ui.resources'] = nil
local resources = require('master.ui.resources')

local mon_empty = { getSize = function() return 40, 30 end }
resources.render(mon_empty, {})

local saw_no_data_text = false
local saw_emergency_badge = false
for _, c in ipairs(calls) do
  if c.fn == 'text' and tostring(c.text):lower():find('keine resource-daten', 1, true) then saw_no_data_text = true end
  if c.fn == 'badge' and c.status == 'EMERGENCY' then saw_emergency_badge = true end
end
if not saw_no_data_text then
  error('expected an honest "keine Daten" placeholder text for an empty resources model')
end
if saw_emergency_badge then
  error('must not render a misleading EMERGENCY badge when no resource data is wired at all')
end

-- Sobald echte Daten da sind, muss die normale Anzeige weiterhin
-- funktionieren (Regressionsschutz gegen den neuen Fruehausstieg).
calls = {}
local mon_data = { getSize = function() return 40, 30 end }
resources.render(mon_data, {
  fuel = { total = 5000, reserve = 2000, minimum = 1000, mix_status = 'SINGLE' },
  water = { total = 9000, target = 10000, buffers = { TANK1 = { level = 9000 } } },
  node_details = {},
  comms = {},
})
local saw_big_number = false
for _, c in ipairs(calls) do
  if c.fn == 'bigNumber' and c.label == 'Fuel Total' then saw_big_number = true end
end
if not saw_big_number then
  error('expected the normal Fuel Total display once real data is present')
end

print('master_resources_no_data_placeholder_test.lua: ok')
