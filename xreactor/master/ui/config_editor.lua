local mux = require("core.mockup_ui")
local hit_cache = setmetatable({}, { __mode = "k" })

local function clamp01(v, min_v, max_v)
  local n = tonumber(v) or min_v
  if max_v <= min_v then return 0 end
  return math.max(0, math.min(1, (n - min_v) / (max_v - min_v)))
end

local function render(mon, model)
  model = model or {}
  local hits = {}
  local w, h = mon.getSize()
  mux.clear(mon)
  mux.header(mon, { title = "AUX CONFIG EDITOR", node_id = "MASTER AUX", page = "EDIT MODE", status = "OK", icon = "config" })
  mux.status_dot(mon, 2, 3, "LIVE APPLY", "OK")
  if w >= 38 then mux.status_dot(mon, math.floor(w * 0.40), 3, "SAFE LIMITS", "LIMITED") end
  if w >= 60 then mux.status_dot(mon, math.floor(w * 0.72), 3, "SYSTEM CONFIG", "OK") end

  local settings = {
    { label = "PEAK THRESHOLD", value = model.peak_threshold_pct or 30, suffix = "%", min = 0, max = 100, delta = 5, type = "peak_threshold_adjust", status = "LIMITED", icon = "energy" },
    { label = "IDLE THRESHOLD", value = model.idle_threshold_pct or 90, suffix = "%", min = 0, max = 100, delta = 5, type = "idle_threshold_adjust", status = "LIMITED", icon = "energy" },
    { label = "RT GLOBAL HOLD", value = model.rt_global_off_hold and 1 or 0, display = model.rt_global_off_hold and "ON" or "OFF", min = 0, max = 1, type = "rt_hold", toggle = true, status = model.rt_global_off_hold and "WARNING" or "OK", icon = "reactor" },
    { label = "FUEL RESERVE", value = model.fuel_reserve_pct or 2000, suffix = "", min = 0, max = 50000, delta = 250, type = "fuel_reserve_adjust", status = "LIMITED", icon = "fuel" },
    { label = "WATER TARGET", value = model.water_target_pct or 0, suffix = "", min = 0, max = 500000, delta = 250, type = "water_target_adjust", status = "LIMITED", icon = "water" },
    { label = "AUTO UPDATE", value = model.auto_update_enabled ~= false and 1 or 0, display = model.auto_update_enabled ~= false and "ON" or "OFF", min = 0, max = 1, type = "auto_update_toggle", toggle = true, status = model.auto_update_enabled ~= false and "OK" or "WARNING", icon = "network" },
    { label = "REACTOR FILL TARGET", value = model.reactor_fill_target_pct or 50, suffix = "%", min = 10, max = 90, delta = 5, type = "reactor_fill_target_adjust", status = "LIMITED", icon = "reactor" },
  }

  local cols = w >= 68 and 3 or (w >= 40 and 2 or 1)
  local gap = 1
  local card_w = math.max(14, math.floor((w - 3 - ((cols - 1) * gap)) / cols))
  local card_h = h >= 24 and 7 or 6
  local start_y = 5

  for i, s in ipairs(settings) do
    local idx = i - 1
    local col = idx % cols
    local row = math.floor(idx / cols)
    local x = 2 + col * (card_w + gap)
    local y = start_y + row * (card_h + 1)
    if y + card_h - 1 <= h - 2 then
      mux.card(mon, x, y, card_w, card_h, { title = s.label, status = s.status, icon = s.icon })
      local shown = s.display or (tostring(s.value) .. tostring(s.suffix or ""))
      mux.data_row(mon, x + 2, y + 1, card_w - 4, { label = "WERT", value = shown, status = s.status, icon = s.icon })
      if not s.toggle then
        mux.outlined_progress(mon, x + 2, y + 3, card_w - 4, clamp01(s.value, s.min, s.max), s.status, shown)
        local cy = y + card_h - 2
        mux.data_row(mon, x + 2, cy, card_w - 4, { label = "[-]", value = "[+]", status = "LIMITED" })
        hits[#hits + 1] = { type = s.type, delta = -s.delta, x1 = x + 2, x2 = x + 4, y1 = cy, y2 = cy }
        hits[#hits + 1] = { type = s.type, delta = s.delta, x1 = x + card_w - 4, x2 = x + card_w - 2, y1 = cy, y2 = cy }
      else
        local cy = y + 3
        mux.banner(mon, x + 2, cy, card_w - 4, s.display or "OFF", s.status, s.icon)
        hits[#hits + 1] = { type = s.type, x1 = x + 2, x2 = x + card_w - 3, y1 = cy, y2 = cy }
      end
    end
  end

  mux.footer_nav(mon, h, w, { left = "[-] SENKEN", center = "LIVE APPLY", right = "[+] ERHOEHEN" })
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
