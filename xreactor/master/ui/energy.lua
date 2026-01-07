local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  ui.panel(mon, 1, 1, w, h, "ENERGY", "OK")
  local percent = model.capacity and model.capacity > 0 and (model.stored or 0) / model.capacity or 0
  ui.bigNumber(mon, 2, 2, "Stored", string.format("%.0f%%", percent * 100), "", model.status)
  ui.progress(mon, 2, 4, w - 4, percent, model.status or "OK")
  local trend = ui.sparkline(model.trend_values or {}, w - 8)
  ui.text(mon, 2, 6, "Trend", colorset.get("text"), colorset.get("background"))
  ui.text(mon, 8, 6, trend, colorset.get(model.status or "OK"), colorset.get("background"))
  ui.text(mon, 2, 7, "Flow", colorset.get("text"), colorset.get("background"))
  ui.text(mon, 8, 7, string.format("In %.0f  Out %.0f  %s", model.input or 0, model.output or 0, model.trend_arrow or "→"), colorset.get("text"), colorset.get("background"))
  local rows = {}
  for _, s in ipairs(model.stores or {}) do
    table.insert(rows, { text = string.format("%s %.0f/%.0f", s.id, s.stored or 0, s.capacity or 0), status = model.status })
  end
  ui.list(mon, 2, 9, w - 2, rows, { max_rows = h - 10 })
end

return { render = render }
