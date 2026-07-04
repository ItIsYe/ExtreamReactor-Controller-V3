local mux = require("core.mockup_ui")
local colors = require("shared.colors")
local utils = require("core.utils")

local cache = {}
local hit_cache = setmetatable({}, { __mode = "k" })

local function safe_section(mon, fn, on_error, label)
  local ok, err = pcall(fn)
  if not ok and on_error then on_error(label, err) end
  return ok
end

local function status_weight(status)
  local s = tostring(status or "OFFLINE"):upper()
  if s == "EMERGENCY" or s == "OFFLINE" then return 5 end
  if s == "WARNING" then return 4 end
  if s == "LIMITED" then return 3 end
  if s == "OK" then return 1 end
  return 2
end

local function node_score(node)
  local score = status_weight(node and node.status) * 1000
  local freshness = tostring(node and node.freshness or ""):lower()
  if freshness == "stale" then score = score + 500 end
  local age = tonumber(node and node.last_seen_age) or -1
  if age > 0 then score = score + math.min(age, 300) end
  return score
end

local function prioritized_nodes(nodes)
  local list = {}
  for _, node in ipairs(nodes or {}) do list[#list + 1] = node end
  table.sort(list, function(a, b)
    local sa, sb = node_score(a), node_score(b)
    if sa ~= sb then return sa > sb end
    return tostring(a and a.id or "") < tostring(b and b.id or "")
  end)
  return list
end

local function render(mon, model)
  local section_errors = {}
  local key = utils.safe_serialize(model) or tostring(model)
  local unchanged = (cache[mon] == key)
  cache[mon] = key

  local w, h = mon.getSize()
  local hits = {}

  mux.clear(mon)
  mux.header(mon, {
    title = "OVERVIEW", page = "PLANT STATUS",
    status = model.system_status or "OK", icon = "master",
    node_id = tostring(model.clock_label or ""),
  })

  -- Statuszeile analog zu den AUX-Seiten: 2-4 status_dots je nach Breite.
  mux.status_dot(mon, 2, 3, "SYSTEM " .. tostring(model.system_status or "OK"), model.system_status or "OK")
  if w >= 30 then
    mux.status_dot(mon, math.floor(w * 0.30), 3, model.auto_profile and "AUTO AN" or "AUTO AUS", model.auto_profile and "LIMITED" or "muted")
  end
  if w >= 46 then
    mux.status_dot(mon, math.floor(w * 0.50), 3, tostring(model.rt_online or 0) .. " RT", (model.rt_online or 0) > 0 and "OK" or "muted")
  end
  if w >= 62 then
    mux.status_dot(mon, math.floor(w * 0.70), 3, tostring(model.nodes_live or 0) .. "/" .. tostring(model.nodes_total or 0) .. " LIVE", (model.nodes_stale or 0) > 0 and "WARNING" or "OK")
  end

  local content_top = 5
  local half_w = math.floor((w - 5) / 2)
  local left_w, right_w = half_w, (w - 3) - half_w - 1
  local top_h = h >= 30 and 13 or 11
  local bottom_y = content_top + top_h + 1
  local bottom_h = math.max(9, h - bottom_y - 1)

  -- ── Steuerung ──────────────────────────────────────────────────────────
  safe_section(mon, function()
    mux.section(mon, 2, content_top, left_w, "STEUERUNG", "OK", "config")
    local y = content_top + 2

    local profiles = model.profile_list or {}
    local pw = math.max(8, math.floor((left_w - (#profiles - 1)) / math.max(1, #profiles)))
    for i, profile in ipairs(profiles) do
      local px = 2 + (i - 1) * (pw + 1)
      local active = model.active_profile == profile
      mux.data_row(mon, px, y, pw, { label = profile, value = active and "*" or "", status = active and "OK" or "muted" })
      hits[#hits + 1] = { type = "profile", name = profile, x1 = px, x2 = px + pw - 1, y1 = y, y2 = y }
    end
    y = y + 2

    local auto_w = math.max(10, math.floor(left_w * 0.45))
    mux.data_row(mon, 2, y, auto_w, { label = "AUTO", value = model.auto_profile and "AN" or "AUS", status = model.auto_profile and "LIMITED" or "muted", icon = "config" })
    hits[#hits + 1] = { type = "auto", x1 = 2, x2 = 2 + auto_w - 1, y1 = y, y2 = y }
    local hold_x = 2 + auto_w + 1
    mux.data_row(mon, hold_x, y, left_w - auto_w - 1, { label = "RT-HOLD", value = model.rt_global_off_hold and "AN" or "AUS", status = model.rt_global_off_hold and "WARNING" or "OK", icon = "reactor" })
    hits[#hits + 1] = { type = "rt_hold", x1 = hold_x, x2 = 2 + left_w - 1, y1 = y, y2 = y }
    y = y + 2

    mux.data_row(mon, 2, y, left_w, { label = "PROFIL", value = tostring(model.active_profile or "-"), status = "text" })
    y = y + 1
    mux.data_row(mon, 2, y, left_w, { label = "SOLL/IST", value = string.format("%.0f / %.0f MRF/t", model.power_target or 0, model.power_actual or 0), status = "muted" })
    y = y + 1
    mux.data_row(mon, 2, y, left_w, { label = "NODES", value = string.format("%d live / %d stale", model.nodes_live or 0, model.nodes_stale or 0), status = "text" })
    y = y + 1

    -- PEAK/IDLE-Schwellwerte: gleiche Touch-Zonen-Logik wie zuvor (String
    -- segmentweise rendern, Positionen dabei mitfuehren), nur ueber
    -- mux-Primitive statt widgets.fit()/ui.text() direkt.
    if h >= 24 then
      local peak_pct = tonumber(model.peak_threshold_pct) or 30
      local idle_pct = tonumber(model.idle_threshold_pct) or 90
      local cx = 2
      local function put(text, color_key)
        local t = tostring(text)
        mon.setCursorPos(cx, y)
        mon.setTextColor(colors.get(color_key or "muted"))
        mon.setBackgroundColor(colors.get("background"))
        mon.write(t)
        local start_x = cx
        cx = cx + #t
        return start_x, cx - 1
      end
      put(string.format("PEAK<%d%% ", peak_pct))
      local pm1, pm2 = put("[-]", "LIMITED")
      put(" ")
      local pp1, pp2 = put("[+]", "LIMITED")
      put("  ")
      put(string.format("IDLE>%d%% ", idle_pct))
      local im1, im2 = put("[-]", "LIMITED")
      put(" ")
      local ip1, ip2 = put("[+]", "LIMITED")
      hits[#hits + 1] = { type = "peak_threshold_adjust", delta = -5, x1 = pm1, x2 = pm2, y1 = y, y2 = y }
      hits[#hits + 1] = { type = "peak_threshold_adjust", delta = 5, x1 = pp1, x2 = pp2, y1 = y, y2 = y }
      hits[#hits + 1] = { type = "idle_threshold_adjust", delta = -5, x1 = im1, x2 = im2, y1 = y, y2 = y }
      hits[#hits + 1] = { type = "idle_threshold_adjust", delta = 5, x1 = ip1, x2 = ip2, y1 = y, y2 = y }
      y = y + 1
      if model.pocket_token then
        mux.data_row(mon, 2, y, left_w, { label = "POCKET-TOKEN", value = tostring(model.pocket_token), status = "muted", icon = "network" })
      end
    end
  end, function(title, err) section_errors[#section_errors + 1] = "Steuerung: " .. tostring(err) end)

  -- ── Meldungen ──────────────────────────────────────────────────────────
  safe_section(mon, function()
    local counts = model.alert_counts or {}
    local severity = (counts.CRITICAL or 0) > 0 and "EMERGENCY" or (((counts.WARN or 0) > 0) and "WARNING" or "OK")
    local rx = 2 + left_w + 1
    mux.section(mon, rx, content_top, right_w, "MELDUNGEN", severity, "warning")
    mux.data_row(mon, rx, content_top + 2, right_w, { label = "C/W/I", value = string.format("%d / %d / %d", counts.CRITICAL or 0, counts.WARN or 0, counts.INFO or 0), status = severity })

    local alerts = model.alert_rows or {}
    local y = content_top + 4
    local max_rows = math.max(1, top_h - 5)
    if #alerts == 0 then
      mux.data_row(mon, rx, y, right_w, { label = "STATUS", value = tostring(model.alert_summary or "Keine aktiven Meldungen"), status = "OK" })
    else
      for i = 1, math.min(#alerts, max_rows) do
        local a = alerts[i]
        mux.data_row(mon, rx, y, right_w, { label = tostring(a.title or "Alert"), value = tostring(a.text or ""), status = a.status or "text" })
        y = y + 1
      end
    end
  end, function(title, err) section_errors[#section_errors + 1] = "Meldungen: " .. tostring(err) end)

  -- ── Kennzahlen ─────────────────────────────────────────────────────────
  safe_section(mon, function()
    mux.section(mon, 2, bottom_y, left_w, "KENNZAHLEN", "OK", "energy")
    local ratio = (model.power_target or 0) > 0 and math.min(1, (model.power_actual or 0) / model.power_target) or 0
    local energy = model.energy_overview or {}
    local gap = 1
    if left_w >= 30 then
      local cw = math.floor((left_w - gap) / 2)
      mux.metric_card(mon, 2, bottom_y + 2, cw, 4, { label = "LEISTUNG", value = string.format("%.0f/%.0f", model.power_target or 0, model.power_actual or 0), unit = "MRF/t", status = "LIMITED", icon = "master" })
      mux.metric_card(mon, 2 + cw + gap, bottom_y + 2, cw, 4, { label = "ENERGIE", value = string.format("%.1f", energy.percent or 0), unit = "%", status = energy.status or "muted", icon = "energy" })
    else
      mux.kpi_strip(mon, 2, bottom_y + 2, left_w, {
        { label = "LEISTUNG", value = string.format("%.0f", model.power_actual or 0), status = "LIMITED", icon = "master" },
        { label = "ENERGIE", value = string.format("%.0f%%", energy.percent or 0), status = energy.status or "muted", icon = "energy" },
      })
    end
    mux.outlined_progress(mon, 2, bottom_y + 7, left_w, ratio, ratio > 0.9 and "WARNING" or "OK", string.format("%.0f%%", ratio * 100))

    local rt_fleet = model.rt_fleet_summary or {}
    mux.data_row(mon, 2, bottom_y + 9, left_w, { label = "RT-FLEET", value = string.format("%d/%d aktiv | %s", rt_fleet.active or 0, rt_fleet.total or 0, tostring(rt_fleet.assignment or "-")), status = rt_fleet.status or "text" })
    local fresh_status = (model.nodes_stale or 0) > 0 and "WARNING" or "OK"
    mux.data_row(mon, 2, bottom_y + 10, left_w, { label = "FRESHNESS", value = string.format("%d live / %d stale", model.nodes_live or 0, model.nodes_stale or 0), status = fresh_status })

    local hints = model.ops_hints or {}
    if hints[1] and bottom_h >= 12 then
      mux.data_row(mon, 2, bottom_y + bottom_h - 1, left_w, { label = "HINWEIS", value = tostring(hints[1]), status = "muted" })
    end
  end, function(title, err) section_errors[#section_errors + 1] = "Kennzahlen: " .. tostring(err) end)

  -- ── Top-Nodes ──────────────────────────────────────────────────────────
  safe_section(mon, function()
    local rx = 2 + left_w + 1
    mux.section(mon, rx, bottom_y, right_w, "TOP-NODES", (model.nodes_stale or 0) > 0 and "WARNING" or "OK", "network")
    mux.table_header(mon, rx, bottom_y + 2, right_w, {
      { label = "NODE", width = math.max(8, math.floor(right_w * 0.30)) },
      { label = "STATUS", width = math.max(8, math.floor(right_w * 0.30)) },
      { label = "SEEN", width = math.max(6, math.floor(right_w * 0.20)) },
    })
    local ordered = prioritized_nodes(model.nodes or {})
    local y = bottom_y + 4
    local max_rows = math.max(1, bottom_h - 5)
    local overflow = #ordered > max_rows
    local show_count = overflow and math.max(1, max_rows - 1) or max_rows
    for i = 1, math.min(#ordered, show_count) do
      local n = ordered[i]
      mux.data_row(mon, rx, y, right_w, {
        label = tostring(n.id or "-"),
        value = tostring(n.status or "OFFLINE") .. "  " .. tostring(n.last_seen_age or -1) .. "s",
        status = n.status or "OFFLINE",
      })
      y = y + 1
    end
    if #ordered == 0 then
      mux.data_row(mon, rx, y, right_w, { label = "STATUS", value = "Keine Nodes sichtbar", status = "muted" })
    elseif overflow then
      mux.data_row(mon, rx, y, right_w, { label = "+" .. tostring(#ordered - show_count), value = "weitere Nodes", status = "muted" })
    end
  end, function(title, err) section_errors[#section_errors + 1] = "Nodes: " .. tostring(err) end)

  if #section_errors > 0 then model.ui_errors = section_errors end
  hit_cache[mon] = hits
  model._overview_render_meta = { cache_unchanged = unchanged, rendered = true }
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
