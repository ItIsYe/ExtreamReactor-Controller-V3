local colors = require("shared.colors")
local mux = require("core.mockup_ui")

local M = {}

local function num(v, fallback)
  if type(v) == "number" then return v end
  if type(v) == "string" then local n = tonumber(v); if n then return n end end
  return fallback
end

local function short(v, suffix)
  local n = num(v, nil)
  if not n then return "-" end
  local a = math.abs(n)
  if a >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if a >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  if a >= 100 then return string.format("%.0f%s", n, suffix or "") end
  return string.format("%.1f%s", n, suffix or "")
end

local function fmt(v, digits, suffix)
  local n = num(v, nil)
  if not n then return "-" end
  return string.format("%." .. tostring(digits or 1) .. "f%s", n, suffix or "")
end

local function snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or {}
end

local function health(model)
  return model and model.health and model.health.status or "OFFLINE"
end

local function bound_count(summary, kind)
  return summary and summary.kinds and summary.kinds[kind] and summary.kinds[kind].bound or 0
end

local function master_key(model)
  if model.master_state == "OK" then return "OK" end
  if model.master_state == "DOWN" then return "WARNING" end
  return "LIMITED"
end

local function capacity_key(model)
  if model.capacity_ready then return "OK" end
  if num(model.capacity_stable_samples, 0) > 0 then return "LIMITED" end
  return "WARNING"
end

local function rt_status(model)
  if not model.capacity_ready then return "KAPAZITAET WIRD GELERNT", "LIMITED" end
  local assignment = tostring(model.assignment_state or "")
  if assignment == "shutdown" then return "SYSTEM FAHRT HERUNTER", "muted" end
  if assignment == "shed" or assignment == "standby" then return "WARTET AUF LASTZUWEISUNG", "muted" end
  if assignment == "startup" then return "SYSTEM FAHRT HOCH", "LIMITED" end
  local s = snapshot(model)
  local target = num(model.target_power, num(s.target_power, 0))
  local actual = num(s.actual_output, 0)
  if target <= 0 then return actual > 0 and "TURBINEN FAHREN AB" or "KEIN MASTER SOLLWERT", "muted" end
  local ratio = actual / target
  if ratio >= 0.85 and ratio <= 1.15 then return "LIEFERT NORMAL", "OK" end
  if ratio < 0.5 then return "LIEFERT ZU WENIG", "EMERGENCY" end
  if ratio > 1.3 then return "LIEFERT ZU VIEL", "WARNING" end
  return "LEISTUNG WEICHT AB", "WARNING"
end

local function page_header(mon, model, title, page, icon)
  mux.clear(mon)
  mux.header(mon, { title = title, node_id = tostring(model.node_id or "RT-?"), page = page, status = health(model), icon = icon })
  local w = ({ mon.getSize() })[1]
  if w >= 40 then
    mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), master_key(model))
    mux.status_dot(mon, math.floor(w * 0.36), 3, model.capacity_ready and "CAP READY" or "LEARNING", capacity_key(model))
    mux.status_dot(mon, math.floor(w * 0.68), 3, tostring(model.assignment_state or "-"):upper(), model.assignment_state == "active" and "OK" or "LIMITED")
  end
  return mon.getSize()
end

function M.render_overview(mon, model)
  local w, h = page_header(mon, model, "RT NODE CONTROL", "SEITE 1/4", "reactor")
  local s = snapshot(model)
  local status_text, status_key = rt_status(model)
  mux.banner(mon, 2, 5, w - 3, status_text, status_key, "reactor")

  local target = num(model.target_power, num(s.target_power, 0))
  local actual = num(s.actual_output, 0)
  local master_pct = num(model.target_percent, num(s.target_percent, 0))
  local capacity = num(model.capacity_max, 0)
  local ratio = capacity > 0 and math.max(0, math.min(1, actual / capacity)) or 0
  local turbines = bound_count(model.summary, "turbine")
  local reactors = bound_count(model.summary, "reactor")

  if w >= 54 and h >= 18 then
    local gap = 1
    local cw = math.floor((w - 4 - gap * 2) / 3)
    mux.metric_card(mon, 2, 7, cw, 4, { label = "SOLL", value = short(target), unit = "RF/t", status = "LIMITED", icon = "master" })
    mux.metric_card(mon, 2 + cw + gap, 7, cw, 4, { label = "IST", value = short(actual), unit = "RF/t", status = status_key, icon = "energy" })
    mux.metric_card(mon, 2 + (cw + gap) * 2, 7, cw, 4, { label = "MASTER SOLL", value = fmt(master_pct, 1, "%"), status = "LIMITED", icon = "master" })

    mux.section(mon, 2, 12, w - 3, "LEISTUNG & KAPAZITAET", "LIMITED", "energy")
    mux.outlined_progress(mon, 2, 14, w - 3, ratio, ratio > 0.9 and "WARNING" or "OK", string.format("%.0f%%", ratio * 100))
    mux.kpi_strip(mon, 2, 16, w - 3, {
      { label = "TURBINEN", value = tostring(turbines), status = "OK", icon = "turbine" },
      { label = "REAKTOREN", value = tostring(reactors), status = reactors > 0 and "OK" or "WARNING", icon = "reactor" },
      { label = "CAPACITY", value = short(capacity, "RF/t"), status = capacity_key(model), icon = "storage" },
      { label = "AVG RPM", value = fmt(s.avg_rpm, 0, ""), status = "OK", icon = "turbine" },
    })
  else
    mux.kpi_strip(mon, 2, 7, w - 3, {
      { label = "SOLL", value = short(target), status = "LIMITED", icon = "master" },
      { label = "IST", value = short(actual), status = status_key, icon = "energy" },
      { label = "M %", value = fmt(master_pct, 0, "%"), status = "LIMITED", icon = "master" },
    })
    mux.section(mon, 2, 10, w - 3, "AUSLASTUNG", "LIMITED", "energy")
    mux.outlined_progress(mon, 2, 12, w - 3, ratio, ratio > 0.9 and "WARNING" or "OK", string.format("%.0f%%", ratio * 100))
    mux.data_row(mon, 2, 14, w - 3, { label = "Turbinen", value = tostring(turbines), status = "OK", icon = "turbine" })
    mux.data_row(mon, 2, 15, w - 3, { label = "Reaktoren", value = tostring(reactors), status = "OK", icon = "reactor" })
  end

  if h >= 20 then
    local r = s.reactors and s.reactors[1] or {}
    mux.section(mon, 2, h - 4, w - 3, "LIVE SUMMARY", "LIMITED", "network")
    mux.data_row(mon, 2, h - 2, w - 3, { label = "Rods " .. fmt(r.rods, 0, "%") .. " | Steam " .. short(s.steam_amount), value = "RPM " .. fmt(s.avg_rpm, 0, ""), status = "text" })
  end
  mux.footer_nav(mon, h, w, { center = "RT OVERVIEW" })
end

function M.render_turbines(mon, model)
  local w, h = page_header(mon, model, "RT TURBINEN", "SEITE 2/4", "turbine")
  local list = snapshot(model).turbines or {}
  local sum_rpm, rpm_n, sum_flow, flow_n, active = 0, 0, 0, 0, 0
  for _, t in ipairs(list) do
    local rpm, flow = num(t.rpm, nil), num(t.flow, nil)
    if rpm then sum_rpm = sum_rpm + rpm; rpm_n = rpm_n + 1 end
    if flow then sum_flow = sum_flow + flow; flow_n = flow_n + 1 end
    if t.inductor == true or t.active == true then active = active + 1 end
  end
  mux.kpi_strip(mon, 2, 5, w - 3, {
    { label = "GESAMT", value = tostring(#list), status = "OK", icon = "turbine" },
    { label = "AKTIV", value = tostring(active), status = "OK", icon = "ok" },
    { label = "AVG RPM", value = rpm_n > 0 and string.format("%.0f", sum_rpm / rpm_n) or "-", status = "OK", icon = "turbine" },
    { label = "AVG FLOW", value = flow_n > 0 and string.format("%.1f", sum_flow / flow_n) or "-", status = "LIMITED", icon = "flow" },
  })

  mux.section(mon, 2, 8, w - 3, "TURBINEN DETAILS", "LIMITED", "turbine")
  local y = 10
  if w >= 50 then
    mux.table_header(mon, 2, y, w - 3, {
      { label = "ID", width = 16 }, { label = "RPM", width = 10 }, { label = "FLOW", width = 11 }, { label = "IND", width = 7 },
    })
  else
    mux.table_header(mon, 2, y, w - 3, {
      { label = "ID", width = 10 }, { label = "RPM", width = 7 }, { label = "FLOW", width = 7 }, { label = "IND", width = 5 },
    })
  end
  y = y + 2
  local max_rows = math.max(1, h - y - 1)
  for i = 1, math.min(#list, max_rows) do
    local t = list[i]
    local ind = t.bound == false and "OFFLINE" or t.inductor == true and "ON" or t.inductor == false and "OFF" or "?"
    local key = ind == "ON" and "OK" or ind == "OFFLINE" and "EMERGENCY" or "muted"
    local id = tostring(t.id or ("T-" .. string.format("%02d", i)))
    local line
    if w >= 50 then
      line = string.format("%-16s %-10s %-11s %-7s", mux.fit(id, 16), t.rpm and string.format("%.0f", t.rpm) or "-", t.flow and string.format("%.1f", t.flow) or "-", ind)
    else
      line = string.format("%-10s %-7s %-7s %-5s", mux.fit(id, 10), t.rpm and string.format("%.0f", t.rpm) or "-", t.flow and string.format("%.1f", t.flow) or "-", ind)
    end
    mux.data_row(mon, 2, y, w - 3, { label = line, value = "", status = key })
    y = y + 1
  end
  mux.footer_nav(mon, h, w, { center = "TURBINEN" })
end

local function reactor_key(r)
  if r.bound == false or r.active == false then return "muted" end
  local temp = num(r.temperature, nil)
  if temp and temp >= 1000 then return "EMERGENCY" end
  if temp and temp >= 850 then return "WARNING" end
  if temp and temp >= 700 then return "LIMITED" end
  return "OK"
end

function M.render_reactors(mon, model)
  local w, h = page_header(mon, model, "RT REAKTOREN", "SEITE 3/4", "reactor")
  local s = snapshot(model)
  local reactors = s.reactors or {}
  local count = math.min(2, #reactors)
  mux.kpi_strip(mon, 2, 5, w - 3, {
    { label = "REAKTOREN", value = tostring(count) .. "/2", status = count > 0 and "OK" or "WARNING", icon = "reactor" },
    { label = "AVG TEMP", value = short(s.avg_temp, "C"), status = "OK", icon = "temperature" },
    { label = "DAMPF", value = short(s.steam_amount), status = "LIMITED", icon = "flow" },
    { label = "MASTER", value = tostring(model.master_state or "?"), status = master_key(model), icon = "master" },
  })

  local y = 8
  if count == 0 then
    mux.warning_box(mon, 2, y, w - 3, { "Keine Reaktoren gefunden", "Discovery / Binding pruefen" }, "WARNING")
  else
    local card_h = h >= 24 and 7 or 6
    for i = 1, count do
      local r = reactors[i]
      local key = reactor_key(r)
      local id = tostring(r.id or ("R-" .. string.format("%02d", i)))
      mux.card(mon, 2, y, w - 3, card_h, { title = id, status = key, icon = "reactor" })
      mux.kpi_strip(mon, 4, y + 1, w - 7, {
        { label = "TEMP", value = fmt(r.temperature, 0, "C"), status = key, icon = "temperature" },
        { label = "RODS", value = fmt(r.rods, 0, "%"), status = "LIMITED", icon = "reactor" },
        { label = "STEAM", value = short(r.steam_production), status = "OK", icon = "flow" },
        { label = "STATE", value = r.active == false and "OFF" or "ACTIVE", status = r.active == false and "muted" or "OK", icon = "ok" },
      })
      if card_h >= 6 then
        mux.outlined_progress(mon, 4, y + card_h - 2, w - 7, math.max(0, math.min(100, num(r.rods, 0))) / 100, "LIMITED", "RODS " .. fmt(r.rods, 0, "%"))
      end
      y = y + card_h + 1
      if y > h - 2 then break end
    end
  end
  mux.footer_nav(mon, h, w, { center = "REAKTOREN" })
end

function M.render_diagnostics(mon, model)
  local w, h = page_header(mon, model, "RT DIAGNOSTICS", "SEITE 4/4", "network")
  local metrics = model.metrics or {}
  local dropped = num(metrics.dropped, 0)
  local retries = num(metrics.retries, 0)
  local net_key = dropped > 0 and "WARNING" or master_key(model)

  mux.kpi_strip(mon, 2, 5, w - 3, {
    { label = "HEALTH", value = health(model), status = health(model), icon = "ok" },
    { label = "MASTER", value = tostring(model.master_state or "?") .. " " .. tostring(model.master_age or ""), status = master_key(model), icon = "master" },
    { label = "TX/RX", value = tostring(metrics.sent or 0) .. "/" .. tostring(metrics.received or 0), status = net_key, icon = "network" },
    { label = "DROP", value = tostring(dropped), status = dropped > 0 and "WARNING" or "OK", icon = "warning" },
  })

  mux.section(mon, 2, 8, w - 3, "SETPOINTS", "LIMITED", "master")
  mux.data_row(mon, 2, 10, w - 3, { label = "Power target", value = short(model.target_power, "RF/t"), status = "LIMITED", icon = "energy" })
  mux.data_row(mon, 2, 11, w - 3, { label = "Master percent", value = fmt(model.target_percent, 1, "%"), status = "LIMITED", icon = "master" })
  mux.data_row(mon, 2, 12, w - 3, { label = "Target RPM", value = short(model.target_rpm), status = "text", icon = "turbine" })
  mux.data_row(mon, 2, 13, w - 3, { label = "Target steam", value = short(model.target_steam), status = "text", icon = "flow" })

  mux.section(mon, 2, 15, w - 3, "SYSTEM", capacity_key(model), "storage")
  mux.data_row(mon, 2, 17, w - 3, { label = "Capacity", value = (model.capacity_ready and "READY " or "LEARNING ") .. short(model.capacity_max, "RF/t"), status = capacity_key(model), icon = "storage" })
  mux.data_row(mon, 2, 18, w - 3, { label = "Retries", value = tostring(retries), status = retries > 0 and "LIMITED" or "OK", icon = "network" })
  mux.data_row(mon, 2, 19, w - 3, { label = "Last command", value = tostring(model.last_command or "none") .. " / " .. tostring(model.last_command_ts or "-"), status = "text", icon = "config" })

  local alerts = model.local_alerts or {}
  if #alerts > 0 and h >= 24 then
    mux.section(mon, 2, 21, w - 3, "AKTIVE ALERTE", "WARNING", "warning")
    local y = 23
    for i = 1, math.min(#alerts, math.max(0, h - y - 1)) do
      local a = alerts[i]
      local sev = tostring(a.severity or "INFO")
      local key = sev == "CRITICAL" and "EMERGENCY" or (sev == "WARN" or sev == "WARNING") and "WARNING" or "LIMITED"
      mux.data_row(mon, 2, y, w - 3, { label = tostring(a.code or sev), value = tostring(a.title or a.message or "alert"), status = key, icon = "warning" })
      y = y + 1
    end
  end
  mux.footer_nav(mon, h, w, { center = "DIAGNOSTICS" })
end

return M
