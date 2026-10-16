-- render_overview() zeigte immer fix "MATRIX A" und "MATRIX B" fuer die
-- ersten beiden Eintraege von model.matrices -- unabhaengig davon, wie die
-- Matrix tatsaechlich heisst/welchen Alias sie hat. Das suggeriert ein festes
-- Zwei-Matrix-Modell, obwohl Discovery 0, 1 oder beliebig viele Matrizen
-- liefern kann (die vollstaendige, korrekt gezaehlte Liste steht bereits auf
-- der MATRICES-Seite). Die Kachel-Labels muessen den echten Alias/ID der
-- jeweiligen Matrix zeigen statt der erfundenen Buchstaben A/B.

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

local model = {
  node_id = 'EN-1',
  total = { percent = 0.5, input = 10, output = 10, stored = 500, capacity = 1000 },
  matrices = {
    { id = 'induction_matrix_7', alias = 'REAKTOR-NORD', percent = 0.42 },
  },
}

metric_cards = {}
pages.render_overview(mon, model)

local labels = {}
for _, c in ipairs(metric_cards) do labels[#labels + 1] = c.label end

local found_real_alias, found_hardcoded_a, found_hardcoded_b = false, false, false
for _, l in ipairs(labels) do
  if l == 'REAKTOR-NORD' then found_real_alias = true end
  if l == 'MATRIX A' then found_hardcoded_a = true end
  if l == 'MATRIX B' then found_hardcoded_b = true end
end

if not found_real_alias then
  error('expected first matrix tile to show the real alias REAKTOR-NORD, got labels: ' .. table.concat(labels, ','))
end
if found_hardcoded_a then
  error('overview must not hardcode the literal label "MATRIX A" when a real alias is known')
end
if found_hardcoded_b then
  error('overview must not hardcode the literal label "MATRIX B" for a missing second matrix')
end

-- Zweite Kachel (kein zweites Matrix-Objekt vorhanden) soll generisch
-- "MATRIX 2" anzeigen, nicht die erfundene Buchstaben-Bezeichnung "MATRIX B".
local found_generic_2 = false
for _, l in ipairs(labels) do
  if l == 'MATRIX 2' then found_generic_2 = true end
end
if not found_generic_2 then
  error('expected the empty second slot to fall back to a generic "MATRIX 2" label, got: ' .. table.concat(labels, ','))
end

print('energy_overview_matrix_tile_labels_test.lua: ok')
