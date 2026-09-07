-- nodes/fuel/monitor_scada.lua
-- Fixed monitor contract and global page footer for the FUEL SCADA UI.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local TARGET_SCALE = 1.0

function M.ensure(mon)
  if not mon or type(mon.getSize) ~= "function" then return false, 0, 0 end
  if type(mon.setTextScale) == "function" then pcall(mon.setTextScale, TARGET_SCALE) end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0 end
  return w == TARGET_W and h == TARGET_H, w, h
end

function M.render_size_error(mon, w, h)
  if not mon then return end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  mux.clear(mon)
  mux.header(mon, { title = "FUEL SCADA - MONITOR FEHLER", node_id = "FUEL", page = "82x40", status = "WARNING", icon = "warning" })
  mux.card(mon, 5, 8, 73, 17, { title = "FESTE BILDSCHIRMGROESSE ERFORDERLICH", status = "WARNING", icon = "warning" })
  mux.text(mon, 8, 12, "Diese FUEL-UI hat bewusst KEIN altes Fallback-Layout.", colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, 8, 15, "Erwartet: 82x40 Zeichen", colorset.get("text"), colorset.get("background"))
  mux.text(mon, 8, 17, "Monitor: 8x6 Advanced Monitor", colorset.get("text"), colorset.get("background"))
  mux.text(mon, 8, 19, "TextScale: 1.0", colorset.get("text"), colorset.get("background"))
  mux.text(mon, 8, 22, "Erkannt: " .. tostring(w) .. "x" .. tostring(h), colorset.get("WARNING"), colorset.get("background"))
end

function M.footer(mon, center)
  local left = mux.button(mon, 2, 38, 22, "<< ZURUECK", "LIMITED", 3)
  local right = mux.button(mon, 59, 38, 22, "WEITER >>", "LIMITED", 3)
  local text = tostring(center or "FUEL")
  local x = math.floor((TARGET_W - #text) / 2) + 1
  mux.text(mon, x, 39, mux.fit(text, 30), colorset.get("muted"), colorset.get("background"))
  return { left = left, right = right }
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.TARGET_SCALE = TARGET_SCALE

return M
