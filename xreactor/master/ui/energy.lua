local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  ui.panel(mon, 1, 1, 50, 18, "ENERGY", colorset.get("accent"), colorset.get("background"))
  ui.text(mon, 2, 2, string.format("Stored: %.0f / %.0f", model.stored or 0, model.capacity or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 3, string.format("In: %.0f Out: %.0f", model.input or 0, model.output or 0), colorset.get("text"), colorset.get("background"))
  local rows = {}
  for _, s in ipairs(model.stores or {}) do
    table.insert(rows, { s.id, string.format("%.0f", s.stored or 0), string.format("%.0f", s.capacity or 0) })
  end
  ui.table(mon, 2, 5, 46, {"ID","Stored","Cap"}, rows, { bg = colorset.get("background"), fg = colorset.get("text"), max_rows = 10 })
end

return { render = render }
