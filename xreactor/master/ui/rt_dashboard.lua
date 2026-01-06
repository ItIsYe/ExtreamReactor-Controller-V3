local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  ui.panel(mon, 1, 1, 60, 18, "RT DASHBOARD", colorset.get("accent"), colorset.get("background"))
  ui.text(mon, 2, 2, "Ramp: " .. tostring(model.ramp_profile or "NORMAL"), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 3, "Sequence: " .. tostring(model.sequence_state or "IDLE"), colorset.get("text"), colorset.get("background"))
  local row = 0
  for _, rt in ipairs(model.rt_nodes or {}) do
    ui.text(mon, 2, 5 + row, rt.id .. " " .. tostring(rt.state), colorset.get("text"), colorset.get("background"))
    local modules = rt.modules or {}
    local sub = 1
    for name, mod in pairs(modules) do
      ui.text(mon, 4, 5 + row + sub, string.format("%s %s %.0f%%", name, mod.state or "OFF", (mod.progress or 0)*100), colorset.get("text"), colorset.get("background"))
      sub = sub + 1
    end
    row = row + sub + 1
  end
  if model.queue then
    local qy = 16
    ui.text(mon, 2, qy, "Queue:", colorset.get("text"), colorset.get("background"))
    local qline = {}
    for _, step in ipairs(model.queue) do
      table.insert(qline, step.module_id or step.node_id)
    end
    ui.text(mon, 10, qy, table.concat(qline, ", "), colorset.get("text"), colorset.get("background"))
  end
end

return { render = render }
