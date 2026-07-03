local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local function own_manifest_version()
  local ok, version = pcall(function()
    if not fs or not fs.exists or not fs.exists("/xreactor/release.lua") then return nil end
    local f = fs.open("/xreactor/release.lua", "r")
    if not f then return nil end
    local raw = f.readAll(); f.close()
    local chunk = load(raw, "=release", "t", {})
    if not chunk then return nil end
    local data = chunk()
    return type(data) == "table" and data.manifest_version or nil
  end)
  if ok then return version end
  return nil
end

local function own_release_id()
  local ok, value = pcall(function()
    if not fs or not fs.exists or not fs.exists("/xreactor/release.lua") then return nil end
    local f = fs.open("/xreactor/release.lua", "r")
    if not f then return nil end
    local raw = f.readAll(); f.close()
    local chunk = load(raw, "=release", "t", {})
    if not chunk then return nil end
    local data = chunk()
    return type(data) == "table" and data.release_id or nil
  end)
  if ok then return value end
  return nil
end

local function status_for(node, own_version)
  if node.offline or node.stale then return "OFFLINE", "muted" end
  local v = tonumber(node.manifest_version)
  if not v or not own_version then return "FEHLER", "EMERGENCY" end
  local diff = own_version - v
  if diff <= 0 then return "OK", "OK" end
  if diff == 1 then return "UPDATE", "LIMITED" end
  return "ALT", "WARNING"
end

local function node_name(node)
  return tostring(node.id or node.node_id or node.name or "?")
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  local own_version = own_manifest_version()
  local release_id = own_release_id() or (own_version and ("beta-v" .. tostring(own_version)) or "?")
  local nodes = (model and model.nodes) or {}

  local attention = 0
  for _, node in ipairs(nodes) do
    local _, key = status_for(node, own_version)
    if key ~= "OK" and key ~= "muted" then attention = attention + 1 end
  end

  ui.panel(mon, 1, 1, w, h, "AUX MONITOR | UPDATES", attention > 0 and "WARNING" or "OK")
  ui.badge(mon, 2, 2, "RELEASE v" .. tostring(own_version or "?"), "OK")
  local bx = math.min(w - 12, 18)
  if bx > 2 then ui.badge(mon, bx, 2, tostring(#nodes) .. " NODES", "OK") end
  local ax = math.max(2, w - 14)
  if ax > bx + 4 then ui.badge(mon, ax, 2, tostring(attention) .. " ATTENTION", attention > 0 and "WARNING" or "OK") end

  local row_y = 5
  ui.text(mon, 2, row_y, widgets.fit("NODE", math.max(8, math.floor(w * 0.35))), colors.get("muted"), colors.get("background"))
  if w >= 34 then ui.text(mon, math.floor(w * 0.48), row_y, "VERSION", colors.get("muted"), colors.get("background")) end
  ui.rightText(mon, 2, row_y, w - 2, "STATUS", colors.get("muted"), colors.get("background"))
  row_y = row_y + 1

  local max_rows = math.max(1, h - row_y - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local label, key = status_for(node, own_version)
    local name = widgets.fit(node_name(node), w >= 50 and 18 or 12)
    local version = (node.offline or node.stale) and "-" or tostring(tonumber(node.manifest_version) or "?")

    if w >= 42 then
      ui.text(mon, 2, row_y, name, colors.get(key), colors.get("background"))
      ui.text(mon, math.floor(w * 0.48), row_y, "v" .. version, colors.get(key), colors.get("background"))
      ui.rightText(mon, 2, row_y, w - 2, label, colors.get(key), colors.get("background"))
    else
      local line = string.format("%-12s v%-5s %s", name, version, label)
      ui.text(mon, 2, row_y, widgets.fit(line, w - 3), colors.get(key), colors.get("background"))
    end
    row_y = row_y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    ui.text(mon, 2, row_y, "Keine Nodes bekannt.", colors.get("muted"), colors.get("background"))
  elseif #nodes > shown and row_y <= h - 2 then
    ui.text(mon, 2, row_y, string.format("... +%d weitere", #nodes - shown), colors.get("muted"), colors.get("background"))
  end

  if h >= 3 then
    local footer = string.format("CURRENT RELEASE %s | %d NODES NEED ATTENTION", tostring(release_id), attention)
    ui.text(mon, 2, h - 1, widgets.fit(footer, w - 3), colors.get(attention > 0 and "WARNING" or "text"), colors.get("background"))
  end
end

return { render = render }
