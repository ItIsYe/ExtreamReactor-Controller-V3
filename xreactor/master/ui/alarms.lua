local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local severity_rank = {
  EMERGENCY = 1,
  WARNING = 2,
  LIMITED = 3,
  OK = 4,
  OFFLINE = 5
}

local function sort_alarms(alarms)
  local sorted = {}
  for _, alarm in ipairs(alarms or {}) do
    table.insert(sorted, alarm)
  end
  table.sort(sorted, function(a, b)
    local ar = severity_rank[a.severity] or 99
    local br = severity_rank[b.severity] or 99
    if ar == br then
      return (a.timestamp or "") > (b.timestamp or "")
    end
    return ar < br
  end)
  return sorted
end

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  local header_status = model.header_blink and "EMERGENCY" or "accent"
  ui.panel(mon, 1, 1, w, h, "ALARMS", header_status)
  local row = 0
  for _, alarm in ipairs(sort_alarms(model.alarms or {})) do
    local clr = colorset.get(alarm.severity) or colorset.get("WARNING")
    ui.text(mon, 2, 3 + row, string.format("%s %s", alarm.timestamp or "--:--", alarm.message or ""), clr, colorset.get("background"))
    row = row + 1
    if 3 + row >= h then break end
  end
end

return { render = render }
