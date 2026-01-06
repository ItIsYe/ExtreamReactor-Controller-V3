local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, alarms)
  local key = textutils.serialize(alarms)
  if cache[mon] == key then return end
  cache[mon] = key
  ui.panel(mon, 1, 1, 60, 18, "ALARMS", colorset.get("accent"), colorset.get("background"))
  local row = 0
  for _, alarm in ipairs(alarms or {}) do
    local clr = colorset.get(alarm.severity) or colorset.get("WARNING")
    ui.text(mon, 2, 3 + row, string.format("%s %s", alarm.timestamp, alarm.message), clr, colorset.get("background"))
    row = row + 1
    if row > 12 then break end
  end
end

return { render = render }
