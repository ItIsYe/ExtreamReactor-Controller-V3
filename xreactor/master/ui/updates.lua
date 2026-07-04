local mux = require("core.mockup_ui")

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
  local w, h = mon.getSize()
  local own_version = own_manifest_version()
  local release_id = own_release_id() or (own_version and ("beta-v" .. tostring(own_version)) or "?")
  local nodes = (model and model.nodes) or {}

  local attention, offline, current = 0, 0, 0
  for _, node in ipairs(nodes) do
    local _, key = status_for(node, own_version)
    if key ~= "OK" and key ~= "muted" then attention = attention + 1 end
    if key == "muted" then offline = offline + 1 end
    if key == "OK" then current = current + 1 end
  end

  local page_status = attention > 0 and "WARNING" or "OK"
  mux.clear(mon)
  mux.header(mon, { title = "AUX UPDATES", node_id = "MASTER AUX", page = "UPDATES", status = page_status, icon = "network" })
  mux.status_dot(mon, 2, 3, "RELEASE v" .. tostring(own_version or "?"), "OK")
  if w >= 42 then mux.status_dot(mon, math.floor(w * 0.38), 3, string.format("NODES %d", #nodes), "OK") end
  if w >= 62 then mux.status_dot(mon, math.floor(w * 0.70), 3, string.format("ATTN %d", attention), attention > 0 and "WARNING" or "OK") end

  if w >= 54 then
    local cw = math.floor((w - 5 - 3) / 4)
    local items = {
      { label = "CURRENT", value = tostring(current), status = "OK", icon = "ok" },
      { label = "UPDATE", value = tostring(attention), status = attention > 0 and "LIMITED" or "OK", icon = "network" },
      { label = "OFFLINE", value = tostring(offline), status = offline > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "RELEASE", value = "v" .. tostring(own_version or "?"), status = "OK", icon = "config" },
    }
    for i, item in ipairs(items) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
  end

  mux.section(mon, 2, 10, w - 3, "> NODE VERSION STATUS", page_status, "network")
  local y = 12
  mux.table_header(mon, 2, y, w - 3, {
    { label = "NODE", width = math.max(12, math.floor((w - 3) * 0.42)) },
    { label = "VERSION", width = math.max(10, math.floor((w - 3) * 0.26)) },
    { label = "STATUS", width = math.max(8, math.floor((w - 3) * 0.30)) },
  })
  y = y + 2

  local max_rows = math.max(1, h - y - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local label, key = status_for(node, own_version)
    local version = (node.offline or node.stale) and "-" or tostring(tonumber(node.manifest_version) or "?")
    local line = string.format("%-18s %-12s %-10s", mux.fit(node_name(node), 18), "v" .. version, label)
    mux.data_row(mon, 2, y, w - 3, { label = line, value = "", status = key, icon = key == "OK" and "ok" or "warning" })
    y = y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    mux.warning_box(mon, 2, y, w - 3, { "Keine Nodes bekannt", "Heartbeat / Registry pruefen" }, "WARNING")
  elseif #nodes > shown and y <= h - 2 then
    mux.data_row(mon, 2, y, w - 3, { label = string.format("+%d weitere Nodes", #nodes - shown), value = "", status = "LIMITED", icon = "network" })
  end

  if h >= 5 then
    mux.banner(mon, 2, h - 4, w - 3, string.format("CURRENT RELEASE %s | %d NODES NEED ATTENTION", tostring(release_id), attention), page_status, "network")
  end
  mux.footer_nav(mon, h, w, { center = "AUX UPDATES" })
end

return { render = render }
