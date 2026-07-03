local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local hit_cache = setmetatable({}, { __mode = "k" })

local function clamp01(v, min_v, max_v)
  local n = tonumber(v) or min_v
  if max_v <= min_v then return 0 end
  return math.max(0, math.min(1, (n - min_v) / (max_v - min_v)))
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  model = model or {}
  local hits = {}
  ui.panel(mon, 1, 1, w, h, "AUX MONITOR | CONFIG EDITOR", "OK")
  ui.badge(mon, math.max(2, w - 16), 2, "EDIT MODE ON", "OK")
  ui.text(mon, 2, 2, "SYSTEM CONFIGURATION", colors.get("LIMITED"), colors.get("background"))

  local cols = w >= 64 and 4 or (w >= 38 and 2 or 1)
  local gap = 1
  local card_w = math.max(12, math.floor((w - 3 - ((cols - 1) * gap)) / cols))
  local start_y = 4
  local card_h = h >= 24 and 6 or 4

  local settings = {
    { label = "PEAK THRESHOLD", value = model.peak_threshold_pct or 30, suffix = "%", min = 0, max = 100, delta = 5, type = "peak_threshold_adjust", status = "LIMITED" },
    { label = "IDLE THRESHOLD", value = model.idle_threshold_pct or 90, suffix = "%", min = 0, max = 100, delta = 5, type = "idle_threshold_adjust", status = "LIMITED" },
    { label = "RT GLOBAL HOLD", value = model.rt_global_off_hold and 1 or 0, display = model.rt_global_off_hold and "ON" or "OFF", min = 0, max = 1, type = "rt_hold", toggle = true, status = model.rt_global_off_hold and "WARNING" or "OK" },
    { label = "FUEL RESERVE", value = model.fuel_reserve_pct or 2000, suffix = "", min = 0, max = 50000, delta = 250, type = "fuel_reserve_adjust", status = "LIMITED" },
    { label = "WATER TARGET", value = model.water_target_pct or 0, suffix = "", min = 0, max = 500000, delta = 250, type = "water_target_adjust", status = "LIMITED" },
    { label = "AUTO UPDATE", value = model.auto_update_enabled ~= false and 1 or 0, display = model.auto_update_enabled ~= false and "ON" or "OFF", min = 0, max = 1, type = "auto_update_toggle", toggle = true, status = model.auto_update_enabled ~= false and "OK" or "WARNING" },
  }

  for i, s in ipairs(settings) do
    local idx = i - 1
    local col = idx % cols
    local row = math.floor(idx / cols)
    local x = 2 + col * (card_w + gap)
    local y = start_y + row * (card_h + 1)
    if y + card_h - 1 <= h - 3 then
      ui.text(mon, x, y, widgets.fit(s.label, card_w), colors.get("muted"), colors.get("background"))
      local shown = s.display or (tostring(s.value) .. tostring(s.suffix or ""))
      ui.text(mon, x, y + 1, widgets.fit(shown, card_w), colors.get(s.status), colors.get("background"))
      if not s.toggle and card_h >= 5 then
        ui.progress(mon, x, y + 2, math.max(5, card_w), clamp01(s.value, s.min, s.max), s.status)
      end

      if s.toggle then
        local label = "[ TOGGLE ]"
        local tx = x + math.max(0, card_w - #label)
        ui.text(mon, tx, y + math.min(card_h - 1, 2), label, colors.get(s.status), colors.get("background"))
        hits[#hits + 1] = { type = s.type, x1 = tx, x2 = tx + #label - 1, y1 = y + math.min(card_h - 1, 2), y2 = y + math.min(card_h - 1, 2) }
      else
        local minus, plus = "[-]", "[+]"
        local cy = y + card_h - 1
        ui.text(mon, x, cy, minus, colors.get("muted"), colors.get("background"))
        ui.text(mon, x + card_w - #plus, cy, plus, colors.get("OK"), colors.get("background"))
        hits[#hits + 1] = { type = s.type, delta = -s.delta, x1 = x, x2 = x + #minus - 1, y1 = cy, y2 = cy }
        hits[#hits + 1] = { type = s.type, delta = s.delta, x1 = x + card_w - #plus, x2 = x + card_w - 1, y1 = cy, y2 = cy }
      end
    end
  end

  if h >= 5 then
    ui.text(mon, 2, h - 3, widgets.fit("INFO: Werte werden direkt angewendet. Wartung ueber AUX MAINTENANCE.", w - 3), colors.get("muted"), colors.get("background"))
    ui.badge(mon, 2, h - 1, "LIVE APPLY", "OK")
    if w >= 34 then ui.badge(mon, math.floor(w * 0.38), h - 1, "SAFE LIMITS", "LIMITED") end
    if w >= 54 then ui.badge(mon, math.floor(w * 0.70), h - 1, "SYSTEM CONFIG", "OK") end
  end

  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
