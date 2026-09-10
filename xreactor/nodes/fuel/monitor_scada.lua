-- nodes/fuel/monitor_scada.lua
--
-- FUEL SCADA monitor contract after the UI rewrite.
--
-- One physical layout only:
--   8x6 Advanced Monitor, TextScale 1.0 => exactly 82x40 cells.
--
-- There is no 0.5 transform, centered viewport, responsive fallback or
-- presentation overlay. Old user configs that still contain ui_scale=0.5 are
-- accepted by the caller, but this module always normalizes the monitor to
-- TextScale 1.0 before rendering.
--
-- Presentation boundary only: no routing/logistics/valve/network decisions.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local TARGET_SCALE = 1.0

local bindings = setmetatable({}, { __mode = "k" })

local function force_scale(mon)
  if not mon then return false end
  if type(mon.getTextScale) == "function" then
    local ok, current = pcall(mon.getTextScale)
    if ok and tonumber(current) == TARGET_SCALE then return true end
  end
  if type(mon.setTextScale) ~= "function" then return false end
  return pcall(mon.setTextScale, TARGET_SCALE) == true
end

function M.normalize_scale(_value) return TARGET_SCALE end
function M.expected_full_size(_value) return TARGET_W, TARGET_H end

function M.ensure(mon, _requested_scale)
  if not mon or type(mon.getSize) ~= "function" then
    return false, 0, 0, nil, TARGET_SCALE
  end
  if not force_scale(mon) then
    return false, 0, 0, nil, TARGET_SCALE
  end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0, nil, TARGET_SCALE end
  if w ~= TARGET_W or h ~= TARGET_H then
    bindings[mon] = nil
    return false, w, h, nil, TARGET_SCALE
  end
  bindings[mon] = {
    mon = mon, target = mon, scale = TARGET_SCALE,
    x = 1, y = 1, w = TARGET_W, h = TARGET_H,
  }
  return true, w, h, mon, TARGET_SCALE
end

function M.touch_to_local(mon, x, y)
  local entry = mon and bindings[mon] or nil
  x, y = tonumber(x), tonumber(y)
  if not entry or not x or not y then return nil, nil, false end
  if x < 1 or x > TARGET_W or y < 1 or y > TARGET_H then
    return nil, nil, false
  end
  return x, y, true
end

function M.get_binding(mon)
  if not (mon and bindings[mon]) then return nil end
  return {
    scale = TARGET_SCALE,
    physical_width = TARGET_W,
    physical_height = TARGET_H,
    logical_width = TARGET_W,
    logical_height = TARGET_H,
    origin_x = 1,
    origin_y = 1,
    fullscreen = true,
  }
end

function M.render_size_error(mon, w, h, _requested_scale)
  if not mon then return end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  mux.clear(mon)
  mux.header(mon, {
    title = "FUEL SCADA - MONITOR FEHLER",
    node_id = "FUEL", page = "82x40",
    status = "WARNING", icon = "warning",
  })
  local box_w = math.max(32, math.min(math.max(w - 4, 32), 76))
  local box_x = math.max(2, math.floor((math.max(w, box_w + 2) - box_w) / 2) + 1)
  mux.card(mon, box_x, 8, box_w, 14, {
    title = "8x6 ADVANCED MONITOR ERFORDERLICH",
    status = "WARNING", icon = "warning",
  })
  mux.text(mon, box_x + 3, 11,
    mux.fit("Feste FUEL-UI: TextScale 1.0 / 82x40.", box_w - 6),
    colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, box_x + 3, 14,
    mux.fit("Erkannt: " .. tostring(w) .. "x" .. tostring(h), box_w - 6),
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 17,
    mux.fit("Keine 0.5-Skalierung und kein Fallback-Layout.", box_w - 6),
    colorset.get("muted"), colorset.get("background"))
end

-- Reserved footer zone is rows 38..40. The two controls occupy only 13x2
-- cells, leaving a wide non-touchable gap around the centered page label.
function M.footer(mon, center)
  local left = mux.button(mon, 3, 38, 13, "<< ZURUECK", "LIMITED", 2)
  local right = mux.button(mon, 67, 38, 13, "WEITER >>", "LIMITED", 2)
  local text = tostring(center or "FUEL")
  local x = math.floor((TARGET_W - #text) / 2) + 1
  mux.text(mon, x, 39, mux.fit(text, 30),
    colorset.get("muted"), colorset.get("background"))
  return { left = left, right = right }
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.TARGET_SCALE = TARGET_SCALE
M.SUPPORTED_SCALES = { 1.0 }
M.FIXED_SCALE = true
M.FOOTER_Y = 38

return M
