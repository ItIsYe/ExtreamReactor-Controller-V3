-- nodes/fuel/half_overview.lua
--
-- Native TextScale-0.5 telemetry overlay for the FUEL Overview page.
-- The regular SCADA renderer still owns all controls and safety-relevant UI.
-- This module draws only into the physically unused middle area of the
-- 164x81 Advanced Monitor after the normal render has completed.
--
-- IMPORTANT: presentation only. No routing, delivery, valve, persistence,
-- network command or safety logic is implemented here. There are no touch
-- controls in this overlay.

local M = {}
local colorset = require("shared.colors")

local PHYSICAL_W = 164
local PHYSICAL_H = 81
local REGION_TOP = 25
local REGION_BOTTOM = 72
local LEFT_X = 2
local RIGHT_X = 84
local COL_W = 79
local SLOT_COUNT = 16
local SLOTS_PER_COL = 8
local SLOT_H = 4

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function fit(value, width)
  local text = tostring(value == nil and "-" or value)
  width = math.max(0, math.floor(tonumber(width) or 0))
  if #text <= width then return text end
  if width <= 0 then return "" end
  if width <= 3 then return text:sub(1, width) end
  return text:sub(1, width - 3) .. "..."
end

local function safe_set(mon, method, value)
  if mon and type(mon[method]) == "function" then pcall(mon[method], value) end
end

local function write_at(mon, x, y, text, fg, bg, width)
  if not mon or type(mon.setCursorPos) ~= "function" or type(mon.write) ~= "function" then return end
  text = fit(text, width or (PHYSICAL_W - x + 1))
  if bg then safe_set(mon, "setBackgroundColor", bg) end
  if fg then safe_set(mon, "setTextColor", fg) end
  pcall(mon.setCursorPos, x, y)
  pcall(mon.write, text)
end

local function clear_line(mon, y, bg)
  safe_set(mon, "setBackgroundColor", bg)
  safe_set(mon, "setTextColor", colorset.get("text"))
  if type(mon.setCursorPos) == "function" and type(mon.write) == "function" then
    pcall(mon.setCursorPos, 1, y)
    pcall(mon.write, string.rep(" ", PHYSICAL_W))
  end
end

local function reactor_key(reactor)
  if type(reactor) ~= "table" then return "muted" end
  if type(reactor.fuel_pct) == "number" and reactor.fuel_pct < 10 then return "EMERGENCY" end
  local state = tostring(reactor.delivery_state or reactor.operational_state or "MISSING")
  if state == "READY" then return "OK" end
  if state == "DELIVERING" or state == "REQUESTING" then return "LIMITED" end
  return "WARNING"
end

local function reactor_state_text(reactor)
  if type(reactor) ~= "table" then return "NICHT KONFIGURIERT" end
  if reactor.fuel_data_state == "STALE" then return "DATEN ALT" end
  if reactor.fuel_data_state == "MISSING" then return "DATEN FEHLEN" end
  local state = tostring(reactor.delivery_state or reactor.operational_state or "MISSING")
  if state == "READY" then return "BEREIT" end
  if state == "DELIVERING" then return "LIEFERUNG" end
  if state == "REQUESTING" then return "ANFORDERUNG" end
  if state == "BLOCKED" then return "BLOCKIERT" end
  return state
end

local function progress_text(pct, width)
  width = math.max(8, width or 48)
  local value = clamp(tonumber(pct) or 0, 0, 100)
  local inner = width - 2
  local filled = math.floor(inner * value / 100 + 0.5)
  return "[" .. string.rep("=", filled) .. string.rep(".", inner - filled) .. "]"
end

local function route_count(reactor)
  if type(reactor) ~= "table" then return 0 end
  if type(reactor.path) == "table" then return #reactor.path end
  if type(reactor.route) == "table" then return #reactor.route end
  return tonumber(reactor.path_len or reactor.route_len) or 0
end

local function draw_slot(mon, x, y, width, index, reactor, bg)
  if type(reactor) ~= "table" then
    write_at(mon, x, y, string.format("%02d  -- NICHT KONFIGURIERT --", index),
      colorset.get("muted"), bg, width)
    write_at(mon, x, y + 1, string.rep("-", math.max(1, width - 2)),
      colorset.get("muted"), bg, width)
    write_at(mon, x, y + 2, "", colorset.get("muted"), bg, width)
    return
  end

  local key = reactor_key(reactor)
  local fg = colorset.get(key)
  local pct = tonumber(reactor.fuel_pct)
  local pct_text = pct and string.format("%3d%%", math.floor(clamp(pct, 0, 100) + 0.5)) or " --%"
  local label = tostring(reactor.label or reactor.reactor_id or ("Reaktor " .. tostring(index)))
  local state = reactor_state_text(reactor)
  local right = pct_text .. "  " .. state
  local left_width = math.max(10, width - #right - 4)

  write_at(mon, x, y,
    string.format("%02d  %s", index, fit(label, left_width)) .. string.rep(" ", 2) .. right,
    fg, bg, width)

  local age = reactor.fuel_age_s ~= nil and (tostring(reactor.fuel_age_s) .. "s") or "--"
  local data = tostring(reactor.fuel_data_state or "-")
  local route = route_count(reactor)
  local delivery = tostring(reactor.delivery_state or reactor.operational_state or "-")
  write_at(mon, x, y + 1,
    string.format("DATA %-8s AGE %-5s ROUTE %-2d  STATE %s", data, age, route, delivery),
    colorset.get(key == "OK" and "muted" or key), bg, width)

  write_at(mon, x, y + 2, progress_text(pct, math.min(width, 58)) .. " " .. pct_text,
    fg, bg, width)
end

local function short_number(value)
  local n = tonumber(value)
  if not n then return "-" end
  if math.abs(n) >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if math.abs(n) >= 1000 then return string.format("%.1fk", n / 1000) end
  return string.format("%.0f", n)
end

function M.render(mon, model)
  if not mon or type(mon.getSize) ~= "function" then return false end
  local ok, w, h = pcall(mon.getSize)
  if not ok or w ~= PHYSICAL_W or h ~= PHYSICAL_H then return false end

  local bg = colorset.get("background")
  for y = REGION_TOP, REGION_BOTTOM do clear_line(mon, y, bg) end

  model = type(model) == "table" and model or {}
  local payload = type(model.payload) == "table" and model.payload or {}
  local logistics = type(payload.logistics) == "table" and payload.logistics or {}
  local reactors = type(logistics.reactors) == "table" and logistics.reactors or {}
  local view = type(model.view_state) == "table" and model.view_state or {}

  local configured = math.min(#reactors, SLOT_COUNT)
  local section_key = configured > 0 and "LIMITED" or "WARNING"
  write_at(mon, 2, 25,
    string.format("REAKTOR-FLOTTE  %d/%d SLOTS   |   0.5 FULLSCREEN / NATIVE KLEINSCHRIFT", configured, SLOT_COUNT),
    colorset.get(section_key), bg, 160)
  write_at(mon, 2, 26, string.rep("-", 160), colorset.get(section_key), bg, 160)

  for slot = 1, SLOT_COUNT do
    local col = slot <= SLOTS_PER_COL and 1 or 2
    local row = (slot - 1) % SLOTS_PER_COL
    local x = col == 1 and LEFT_X or RIGHT_X
    local y = 28 + row * SLOT_H
    draw_slot(mon, x, y, COL_W, slot, reactors[slot], bg)
  end

  write_at(mon, 2, 61, string.rep("-", 160), colorset.get("muted"), bg, 160)
  local reserve = short_number(payload.reserve)
  local minimum = short_number(payload.minimum_reserve)
  local logistics_state = logistics.enabled == true and "AN" or "AUS"
  local export = tostring(logistics.export_chest or "NICHT GESETZT")
  write_at(mon, 2, 62,
    string.format("LOGISTIK %-3s   RESERVE %s / MIN %s   EXPORT %s", logistics_state, reserve, minimum, export),
    colorset.get(logistics.enabled == true and "OK" or "LIMITED"), bg, 160)

  local view_code = tostring(view.code or "-")
  local view_title = tostring(view.title or "")
  local detail = tostring(view.detail or "")
  write_at(mon, 2, 64,
    "SCADA " .. view_code .. (view_title ~= "" and ("  |  " .. view_title) or "") .. (detail ~= "" and ("  |  " .. detail) or ""),
    colorset.get(view.severity or "muted"), bg, 160)

  if view.action and tostring(view.action) ~= "" then
    write_at(mon, 2, 66, "OPERATOR: " .. tostring(view.action),
      colorset.get(view.severity == "OK" and "muted" or "WARNING"), bg, 160)
  end

  write_at(mon, 2, 70,
    "INFO: Dieser Bereich ist reine Telemetrie. Bedienung bleibt auf den sichtbaren SCADA-Buttons.",
    colorset.get("muted"), bg, 160)

  return true
end

M.PHYSICAL_W = PHYSICAL_W
M.PHYSICAL_H = PHYSICAL_H
M.REGION_TOP = REGION_TOP
M.REGION_BOTTOM = REGION_BOTTOM
M.SLOT_COUNT = SLOT_COUNT

return M
