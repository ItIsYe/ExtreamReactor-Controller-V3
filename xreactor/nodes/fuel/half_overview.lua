-- nodes/fuel/half_overview.lua
--
-- Native TextScale-0.5 concept-pass overlay for the FUEL Overview page.
--
-- Goal of this revision:
--   * stronger panel framing
--   * larger-feeling typography by using fewer lines per item
--   * all 16 reactor slots remain visible
--   * unconfigured reactors stay explicitly labeled
--   * no new controls, routing, logistics, valve or persistence behavior
--
-- IMPORTANT: presentation only. This module has no touch handling and no
-- control calls. The existing SCADA renderer still owns all interaction.

local M = {}
local colorset = require("shared.colors")

local PHYSICAL_W = 164
local PHYSICAL_H = 81
local REGION_TOP = 25
local REGION_BOTTOM = 72
local SLOT_COUNT = 16
local SLOTS_PER_COL = 8
local COL_LEFT_X = 2
local COL_RIGHT_X = 84
local COL_W = 79
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

local function fill_line(mon, x, y, width, ch, fg, bg)
  write_at(mon, x, y, string.rep(ch or " ", math.max(0, width or 0)), fg, bg, width)
end

local function clear_line(mon, y, bg)
  fill_line(mon, 1, y, PHYSICAL_W, " ", colorset.get("text"), bg)
end

local function draw_box(mon, x, y, w, h, title, key, bg)
  if w < 4 or h < 3 then return end
  local fg = colorset.get(key or "muted")
  local top = "+" .. string.rep("-", w - 2) .. "+"
  local bottom = top
  write_at(mon, x, y, top, fg, bg, w)
  for yy = y + 1, y + h - 2 do
    write_at(mon, x, yy, "|", fg, bg, 1)
    if w > 2 then fill_line(mon, x + 1, yy, w - 2, " ", fg, bg) end
    write_at(mon, x + w - 1, yy, "|", fg, bg, 1)
  end
  write_at(mon, x, y + h - 1, bottom, fg, bg, w)
  if title and title ~= "" then
    local label = " " .. fit(title, math.max(1, w - 6)) .. " "
    local tx = x + math.max(1, math.floor((w - #label) / 2))
    write_at(mon, tx, y, label, fg, bg, #label)
  end
end

local function short_number(value, suffix)
  local n = tonumber(value)
  if not n then return "-" end
  if math.abs(n) >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if math.abs(n) >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function reactor_key(reactor)
  if type(reactor) ~= "table" then return "muted" end
  local pct = tonumber(reactor.fuel_pct)
  if pct and pct < 10 then return "EMERGENCY" end
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

local function route_count(reactor)
  if type(reactor) ~= "table" then return 0 end
  if type(reactor.path) == "table" then return #reactor.path end
  if type(reactor.route) == "table" then return #reactor.route end
  return tonumber(reactor.path_len or reactor.route_len) or 0
end

local function progress_text(pct, width)
  width = math.max(12, width or 32)
  local value = clamp(tonumber(pct) or 0, 0, 100)
  local inner = width - 2
  local filled = math.floor(inner * value / 100 + 0.5)
  return "[" .. string.rep("=", filled) .. string.rep(".", inner - filled) .. "]"
end

local function draw_summary_box(mon, x, y, w, title, value, detail, key, bg)
  draw_box(mon, x, y, w, 7, title, key, bg)
  write_at(mon, x + 3, y + 2, fit(value, w - 6), colorset.get(key or "text"), bg, w - 6)
  write_at(mon, x + 3, y + 4, fit(detail, w - 6), colorset.get("muted"), bg, w - 6)
end

local function draw_slot(mon, x, y, width, index, reactor, bg)
  local inner_w = width - 4
  local start_x = x + 2
  local top_y = y

  if type(reactor) ~= "table" then
    write_at(mon, start_x, top_y,
      string.format("%02d  NICHT KONFIGURIERT", index),
      colorset.get("muted"), bg, inner_w)
    write_at(mon, start_x, top_y + 1, "freier Reaktor-Slot",
      colorset.get("muted"), bg, inner_w)
    write_at(mon, start_x, top_y + 2, string.rep("-", inner_w - 2),
      colorset.get("muted"), bg, inner_w)
    return
  end

  local key = reactor_key(reactor)
  local fg = colorset.get(key)
  local pct = tonumber(reactor.fuel_pct)
  local pct_text = pct and string.format("%d%%", math.floor(clamp(pct, 0, 100) + 0.5)) or "--%"
  local label = tostring(reactor.label or reactor.reactor_id or ("Reaktor " .. tostring(index)))
  local state = reactor_state_text(reactor)
  local age = reactor.fuel_age_s ~= nil and (tostring(reactor.fuel_age_s) .. "s") or "--"
  local route = route_count(reactor)

  write_at(mon, start_x, top_y,
    string.format("%02d  %s", index, fit(label, math.max(10, inner_w - #pct_text - 6))),
    fg, bg, inner_w)
  write_at(mon, start_x + inner_w - #pct_text, top_y, pct_text, fg, bg, #pct_text)
  write_at(mon, start_x, top_y + 1,
    string.format("%s   Route %d   Alter %s", state, route, age),
    colorset.get(key == "OK" and "text" or key), bg, inner_w)
  write_at(mon, start_x, top_y + 2, progress_text(pct, math.min(40, inner_w - #pct_text - 1)), fg, bg, inner_w)
  write_at(mon, start_x + math.min(42, inner_w - #pct_text), top_y + 2, pct_text,
    fg, bg, #pct_text)
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
  local ready = 0
  for i = 1, configured do
    if reactor_state_text(reactors[i]) == "BEREIT" then ready = ready + 1 end
  end
  local reserve = short_number(payload.reserve, " mB")
  local minimum = short_number(payload.minimum_reserve, " mB")
  local logistics_state = logistics.enabled == true and "AKTIV" or "AUS"
  local export = tostring(logistics.export_chest or "NICHT GESETZT")

  draw_summary_box(mon, 2, 25, 52,
    "RESERVE",
    reserve,
    "Minimum " .. minimum,
    tonumber(payload.reserve or 0) >= tonumber(payload.minimum_reserve or 0) and "OK" or "WARNING",
    bg)
  draw_summary_box(mon, 56, 25, 52,
    "REAKTOREN",
    string.format("%d / %d konfiguriert", configured, SLOT_COUNT),
    string.format("%d bereit", ready),
    configured > 0 and "LIMITED" or "WARNING",
    bg)
  draw_summary_box(mon, 110, 25, 53,
    "LOGISTIK",
    logistics_state,
    fit("Export " .. export, 45),
    logistics.enabled == true and "OK" or "LIMITED",
    bg)

  write_at(mon, 2, 33, "REAKTORFLOTTE", colorset.get("LIMITED"), bg, 40)
  draw_box(mon, COL_LEFT_X, 34, COL_W, 33, "SLOTS 01-08", "LIMITED", bg)
  draw_box(mon, COL_RIGHT_X, 34, COL_W, 33, "SLOTS 09-16", "LIMITED", bg)

  for slot = 1, SLOT_COUNT do
    local col = slot <= SLOTS_PER_COL and 1 or 2
    local row = (slot - 1) % SLOTS_PER_COL
    local x = col == 1 and COL_LEFT_X or COL_RIGHT_X
    local y = 36 + row * SLOT_H
    draw_slot(mon, x, y, COL_W, slot, reactors[slot], bg)
  end

  draw_box(mon, 2, 68, 161, 5, "SCADA", "muted", bg)
  local scada = tostring(view.code or "-")
  local detail = tostring(view.detail or "")
  local line = "SCADA " .. scada
  if detail ~= "" then line = line .. "  |  " .. detail end
  write_at(mon, 5, 70, line, colorset.get(view.severity or "muted"), bg, 154)
  write_at(mon, 5, 71,
    "Hinweis: unkonfigurierte Reaktoren bleiben sichtbar. Bedienung nur ueber die SCADA-Buttons unten.",
    colorset.get("muted"), bg, 154)

  return true
end

M.PHYSICAL_W = PHYSICAL_W
M.PHYSICAL_H = PHYSICAL_H
M.REGION_TOP = REGION_TOP
M.REGION_BOTTOM = REGION_BOTTOM
M.SLOT_COUNT = SLOT_COUNT
M.SLOTS_PER_COL = SLOTS_PER_COL

return M
