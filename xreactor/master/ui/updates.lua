-- xreactor/master/ui/updates.lua
--
-- AUX-Monitor-Seite: Update-Status pro Node (Feature, 2026-07-02).
--
-- Zweck: auf einen Blick sehen, ob alle Nodes dieselbe manifest_version
-- haben wie MASTER selbst. Nodes senden ihre Version automatisch mit jedem
-- Heartbeat (siehe services/heartbeat_service.lua), der Master speichert
-- sie in node.manifest_version (siehe master/message_handlers.lua).
--
-- Farblogik:
--   Grün   = Version stimmt exakt mit MASTER überein
--   Gelb   = Version ist genau 1 hinter MASTER (Update sollte in Kürze
--            durch den Auto-Updater ankommen — kein Grund zur Sorge)
--   Orange = Version liegt 2+ hinter MASTER zurück (deutlich veraltet,
--            Auto-Updater greift offenbar nicht wie erwartet)
--   Rot    = Version unbekannt (nie ein Heartbeat mit manifest_version
--            empfangen) oder Node antwortet mit einem Fehlerzustand
--   Grau   = Node offline/stale

local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function own_manifest_version()
  local ok, version = pcall(function()
    if not fs or not fs.exists or not fs.exists("/xreactor/release.lua") then return nil end
    local f = fs.open("/xreactor/release.lua", "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    local chunk = load(raw, "=release", "t", {})
    if not chunk then return nil end
    local data = chunk()
    return type(data) == "table" and data.manifest_version or nil
  end)
  if ok then return version end
  return nil
end

local function status_for(node, own_version)
  if node.offline or node.stale then return "GRAU", "muted" end
  local v = tonumber(node.manifest_version)
  if not v or not own_version then return "UNBEKANNT", "EMERGENCY" end
  local diff = own_version - v
  if diff <= 0 then return "OK", "OK" end
  if diff == 1 then return "UPDATE", "LIMITED" end
  return "ALT", "WARNING"
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local own_version = own_manifest_version()
  ui.panel(mon, 1, 1, w, h, "AUX:UPDATES", "OK")
  ui.text(mon, 2, 2, widgets.fit("MASTER-Version: " .. tostring(own_version or "?"), w - 2), colors.get("text"), colors.get("background"))

  local nodes = (model and model.nodes) or {}
  local row_y = 4
  local max_rows = math.max(1, h - 5)
  local shown = 0
  local mismatch_count = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local label, status_color = status_for(node, own_version)
    if status_color ~= "OK" and status_color ~= "muted" then mismatch_count = mismatch_count + 1 end
    local id_text = widgets.fit(tostring(node.id or "?"), 14)
    local ver_text = node.offline or node.stale
      and "offline"
      or (tostring(tonumber(node.manifest_version) or "?"))
    local line = string.format("%-14s v%-6s %s", id_text, ver_text, label)
    ui.text(mon, 2, row_y, widgets.fit(line, w - 2), colors.get(status_color), colors.get("background"))
    row_y = row_y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    ui.text(mon, 2, row_y, "Keine Nodes bekannt.", colors.get("muted"), colors.get("background"))
  end

  local footer_status = mismatch_count > 0 and "WARNING" or "OK"
  ui.badge(mon, 2, h, string.format("%d Node(s) nicht aktuell", mismatch_count), footer_status)
end

return { render = render }
