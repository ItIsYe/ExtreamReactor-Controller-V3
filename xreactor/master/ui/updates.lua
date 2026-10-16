local mux = require("core.mockup_ui")
local build_info = require("shared.build_info")

-- Eigene Fassung aus /xreactor/release.lua -- einmal gelesen je Zeichnung
-- (bis v814 las die Seite die Datei dafuer zweimal).
local function own_release()
  local ok, data = pcall(function()
    if not fs or not fs.exists or not fs.exists("/xreactor/release.lua") then return nil end
    local f = fs.open("/xreactor/release.lua", "r")
    if not f then return nil end
    local raw = f.readAll(); f.close()
    local chunk = load(raw, "=release", "t", {})
    if not chunk then return nil end
    return chunk()
  end)
  if ok and type(data) == "table" then return data end
  return {}
end

-- Ergebnis der Dateipruefung (core/install_integrity.lua, Zusammenfassung
-- aus shared/build_info.lua's integrity_summary()):
--
--   "OK"      alle Dateien passen zu ihren Pruefsummen
--   "3 ABW"   3 Dateien fehlen oder weichen ab -- der Auto-Updater
--             installiert dann einmal neu (installer/auto_update.lua)
--   "-"       keine Pruefsummenliste (vor v814 installiert)
--   "?"       noch nicht geprueft (das geschieht beim ersten Update-Check
--             nach dem Start) oder geprueft gegen eine andere Fassung als
--             die, die der Knoten gerade meldet
--
-- Zweiter Rueckgabewert: true/false/nil -- passt / passt nicht / unbekannt.
local function files_state(integrity, manifest_version)
  if type(integrity) ~= "table" then return "?", nil end
  local reported = tonumber(manifest_version)
  local checked = tonumber(integrity.version)
  if reported and checked and reported ~= checked then return "?", nil end
  if integrity.ok == true then return "OK", true end
  if integrity.ok == false then return string.format("%d ABW", tonumber(integrity.bad) or 0), false end
  return "-", nil
end

local function status_for(node, own_version)
  if node.offline or node.stale then return "OFFLINE", "muted" end
  local v = tonumber(node.manifest_version)
  if not v or not own_version then return "FEHLER", "EMERGENCY" end
  local diff = own_version - v
  if diff <= 0 then
    -- Aktuelle Fassung, aber Dateien, die nicht zu ihr passen: das braucht
    -- Aufmerksamkeit genauso wie eine alte Fassung.
    local _, files_ok = files_state(node.integrity, node.manifest_version)
    if files_ok == false then return "DATEIEN", "WARNING" end
    return "OK", "OK"
  end
  if diff == 1 then return "UPDATE", "LIMITED" end
  return "ALT", "WARNING"
end

local function node_name(node)
  return tostring(node.id or node.node_id or node.name or "?")
end

-- Zelle fester Breite: gekuerzt UND aufgefuellt, mit einem Leerzeichen
-- Abstand zur naechsten Spalte.
local function cell(text, width)
  local t = mux.fit(tostring(text or ""), math.max(1, width - 1))
  return t .. string.rep(" ", math.max(0, width - #t))
end

local function render(mon, model)
  local w, h = mon.getSize()
  local release = own_release()
  local own_version = tonumber(release.manifest_version)
  local release_id = release.release_id or (own_version and ("beta-v" .. tostring(own_version)) or "?")
  local nodes = (model and model.nodes) or {}

  -- MASTERs eigene Dateipruefung: dieselbe Zusammenfassung, die jeder
  -- Knoten im STATUS-Paket schickt.
  local own_files = files_state(build_info.integrity_summary(), own_version)

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
  -- Dieselben Spaltenbreiten fuer Kopf und Zeilen; die Zeilen beginnen mit
  -- dem Symbol "[*] ", das die erste Spalte entsprechend kuerzer macht.
  local inner = w - 3
  local widths = {
    math.max(12, math.floor(inner * 0.38)),
    math.max(8, math.floor(inner * 0.18)),
    math.max(9, math.floor(inner * 0.22)),
    math.max(8, math.floor(inner * 0.20)),
  }
  mux.table_header(mon, 2, y, inner, {
    { label = "NODE", width = widths[1] },
    { label = "VERSION", width = widths[2] },
    { label = "STATUS", width = widths[3] },
    { label = "DATEIEN", width = widths[4] },
  })
  y = y + 2

  local max_rows = math.max(1, h - y - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local label, key = status_for(node, own_version)
    local gone = node.offline or node.stale
    local version = gone and "-" or tostring(tonumber(node.manifest_version) or "?")
    local files = gone and "-" or (files_state(node.integrity, node.manifest_version))
    local icon = key == "OK" and "ok" or "warning"
    local prefix_len = #("[" .. mux.icon(icon) .. "] ")
    local line = cell(node_name(node), math.max(1, widths[1] - prefix_len))
      .. cell("v" .. version, widths[2]) .. cell(label, widths[3]) .. cell(files, widths[4])
    mux.data_row(mon, 2, y, inner, { label = line, value = "", status = key, icon = icon })
    y = y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    mux.warning_box(mon, 2, y, inner, { "Keine Nodes bekannt", "Heartbeat / Registry pruefen" }, "WARNING")
  elseif #nodes > shown and y <= h - 2 then
    mux.data_row(mon, 2, y, inner, { label = string.format("+%d weitere Nodes", #nodes - shown), value = "", status = "LIMITED", icon = "network" })
  end

  if h >= 5 then
    mux.banner(mon, 2, h - 4, inner, string.format("CURRENT RELEASE %s | MASTER DATEIEN %s | %d NODES NEED ATTENTION",
      tostring(release_id), own_files, attention), page_status, "network")
  end
end

return { render = render, files_state = files_state, status_for = status_for }
