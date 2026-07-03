-- xreactor/master/ui/maintenance.lua
--
-- Wartungsmodus-Verwaltungsseite (Feature, 2026-07-02).
--
-- Zweck: Wartungsmodus existierte bisher nur implizit pro RT-Node (Touch
-- auf die Kartentitel-Zeile in rt_dashboard.lua). Diese Seite zeigt ALLE
-- Nodes über alle Rollen hinweg mit ihrem AUTO/MAINTENANCE-Status auf
-- einen Blick, und erlaubt das Umschalten per Touch auch fuer Nicht-RT-
-- Rollen (Energy, Water, Fuel, Log), wo es bisher gar keine UI dafuer gab.
--
-- Wichtig (siehe Anforderung): Wartung ist NICHT dasselbe wie offline.
-- Ein Node in Wartung bleibt sichtbar/online, wird aber anders bewertet:
--   - RT in Wartung: komplett aus der Lastzuweisung genommen
--     (rt_sync.evaluate_rt_node() prioritaet MAINTENANCE vor GLOBAL_HOLD)
--   - Support-Node (Energy/Water/Fuel/Reprocessor) in Wartung: bleibt
--     sichtbar, wird aber in der Bewertung als "erwartete Abweichung"
--     markiert statt als echtes Problem
--   - LOG in Wartung: loest KEINE Anlagenstoerung aus (LIMITED statt
--     WARNING Status)

local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local hit_cache = setmetatable({}, { __mode = "k" })

local function status_for_row(node)
  if node.maintenance_mode then
    return node.status or "WARNING"
  end
  return "OK"
end

local function label_for_row(node)
  return node.maintenance_mode and "MAINTENANCE" or "AUTO"
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "Maintenance", "OK")
  local hits = {}

  local nodes = (model and model.nodes) or {}
  local box = widgets.panel_box(mon, 2, 2, w - 2, h - 3, "Node-Wartungsstatus", "OK")
  ui.text(mon, box.x, box.y, widgets.fit("Zeile antippen = AUTO/MAINTENANCE umschalten", box.w), colors.get("muted"), colors.get("background"))

  local row_y = box.y + 2
  local max_rows = math.max(1, box.h - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local id_text = widgets.fit(tostring(node.id or "?"), 14)
    local role_text = widgets.fit(tostring(node.role or "?"), 16)
    local label = label_for_row(node)
    local status = status_for_row(node)
    local line = string.format("%-14s %-16s %s", id_text, role_text, label)
    ui.text(mon, box.x, row_y, widgets.fit(line, box.w), colors.get(status), colors.get("background"))
    hits[#hits + 1] = { type = "maintenance_toggle", node_id = node.id, x1 = box.x, x2 = box.x + box.w - 1, y1 = row_y, y2 = row_y }
    row_y = row_y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    ui.text(mon, box.x, row_y, "Keine Nodes bekannt.", colors.get("muted"), colors.get("background"))
  elseif #nodes > shown then
    ui.text(mon, box.x, row_y, widgets.fit(string.format("+%d weitere Nodes — nur die ersten %d angezeigt", #nodes - shown, shown), box.w), colors.get("muted"), colors.get("background"))
  end

  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
