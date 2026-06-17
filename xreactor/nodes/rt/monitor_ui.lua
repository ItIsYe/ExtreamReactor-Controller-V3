local ui = require("core.ui")
local ui_router = require("core.ui_router")
local colors = require("shared.colors")
local support_ui_pages = require("nodes.support.ui_pages")
local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local M = {
  monitor_router = nil,
  last_monitor_update = 0
}

local function try_set_scale(monitor, scale)
  if monitor and type(scale) == "number" then ui.setScale(monitor, scale) end
end

local function normalize_monitor_result(result)
  if type(result) == "table" then
    if result.mon then return result.mon, result.name end
    if result.monitor then return result.monitor, result.name end
  end
  return result
end

local function resolve_monitor(monitor_adapter, preferred_name, monitor_scale)
  if type(monitor_adapter) ~= "table" then return nil, "monitor adapter missing" end
  if type(monitor_adapter.find) == "function" then
    local monitor, name = normalize_monitor_result(monitor_adapter.find(preferred_name, "first", monitor_scale, "RT"))
    if monitor then return monitor, name end
  end
  if type(monitor_adapter.wrap) == "function" and preferred_name then
    local monitor = monitor_adapter.wrap(preferred_name)
    if monitor then try_set_scale(monitor, monitor_scale); return monitor, preferred_name end
  end
  if preferred_name and peripheral and type(peripheral.wrap) == "function" then
    local monitor = peripheral.wrap(preferred_name)
    if monitor then try_set_scale(monitor, monitor_scale); return monitor, preferred_name end
  end
  return nil, preferred_name and ("monitor unavailable: " .. tostring(preferred_name)) or "no monitor found"
end

local function num(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then local parsed = tonumber(value); if parsed then return parsed end end
  return fallback
end

local function fit(text, width)
  local raw = tostring(text or ""):gsub("\n", " "):gsub("\r", " ")
  local w = math.max(1, tonumber(width) or #raw)
  if #raw <= w then return raw end
  if w <= 2 then return raw:sub(1, w) end
  return raw:sub(1, w - 1) .. "~"
end

local function pad(text, width)
  local w = math.max(1, tonumber(width) or 1)
  local clipped = fit(text, w)
  return clipped .. string.rep(" ", math.max(0, w - #clipped))
end

local function fmt(value, digits, suffix)
  local n = num(value, nil)
  if not n then return "-" end
  return string.format("%." .. tostring(digits or 1) .. "f%s", n, suffix or "")
end

local function fmt_short(value, suffix)
  local n = num(value, nil)
  if not n then return "-" end
  local abs = math.abs(n)
  if abs >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if abs >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  if abs >= 100 then return string.format("%.0f%s", n, suffix or "") end
  return string.format("%.1f%s", n, suffix or "")
end

local function count_bound(summary, kind)
  return summary and summary.kinds and summary.kinds[kind] and summary.kinds[kind].bound or 0
end

local function monitor_snapshot(model)
  return model and model.snapshot and model.snapshot.snapshot or nil
end

local function status_color(status)
  return colors.get(status or "text")
end

local function power_state(actual, target)
  local a = num(actual, 0)
  local t = num(target, 0)
  if t <= 0 then return "LIMITED", 0 end
  local pct = math.max(0, math.min(150, (a / t) * 100))
  if pct < 25 or pct > 115 then return "WARNING", pct end
  return "OK", pct
end

local function master_status(model)
  if model.master_state == "DOWN" then return "WARNING" end
  if model.master_state == "OK" then return "OK" end
  return "LIMITED"
end

local function capacity_status(model)
  if model.capacity_ready then return "OK" end
  if (num(model.capacity_stable_samples, 0) or 0) > 0 then return "LIMITED" end
  return "WARNING"
end

local function write_line(mon, y, text, status)
  local w = ({ ui.getSize(mon) })[1] or 20
  if y < 1 then return end
  ui.text(mon, 2, y, fit(text, math.max(1, w - 3)), status_color(status), colors.get("background"))
end

local function badge_line(mon, y, badges)
  local w = ({ ui.getSize(mon) })[1] or 20
  local x = 2
  for _, b in ipairs(badges or {}) do
    if x >= w then break end
    local label = fit(b[1], math.max(3, math.min(10, w - x)))
    ui.badge(mon, x, y, label, b[2] or "OK")
    x = x + #label + 2
  end
end

local function clear_and_title(mon, title, status)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, title, status or "OK")
  return w, h
end

local function table_header(mon, y, labels, widths)
  local x = 2
  for i, label in ipairs(labels or {}) do
    local cw = widths[i] or 8
    ui.text(mon, x, y, pad(label, cw - 1), colors.get("muted"), colors.get("background"))
    x = x + cw
  end
end

local function table_row(mon, y, values, widths, status, status_col)
  local x = 2
  for i, value in ipairs(values or {}) do
    local cw = widths[i] or 8
    local key = (i == (status_col or 1)) and (status or "text") or (i == #values and "muted" or "text")
    ui.text(mon, x, y, pad(value or "-", cw - 1), colors.get(key), colors.get("background"))
    x = x + cw
  end
end

local function render_compact_header(mon, model, title)
  local health = model.health and model.health.status or "OFFLINE"
  badge_line(mon, 2, {
    { "RT " .. tostring(health), health },
    { "M " .. tostring(model.master_state or "?"), master_status(model) },
    { tostring(model.current_state or "-"), tostring(model.current_state) == "MASTER" and "OK" or "LIMITED" },
    { model.capacity_ready and "CAP" or "LEARN", capacity_status(model) }
  })
  write_line(mon, 3, tostring(title) .. " | " .. tostring(model.node_id or "?") .. " | " .. tostring(model.node_state or "-"), "text")
  return 4
end

local function render_overview(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local summary  = model.summary or {}
  local health   = model.health and model.health.status or "OFFLINE"
  local w, h     = clear_and_title(mon, "RT OVERVIEW", health)
  local y        = render_compact_header(mon, model, "Overview")
  local actual   = num(snapshot.actual_output, 0)
  local target   = num(model.target_power, num(snapshot.target_power, 0))
  local p_status, p_pct = power_state(actual, target)
  local capacity = num(model.capacity_max, 0)
  local cap_pct  = capacity > 0 and math.min(100, (actual / capacity) * 100) or 0
  local reactors = count_bound(summary, "reactor")
  local turbines = count_bound(summary, "turbine")

  -- ── Statuszeilen: volle Breite, wie gehabt ────────────────────────────
  write_line(mon, y, string.format("Power %s%%  Soll %s  Ist %s", fmt(p_pct, 1), fmt_short(target), fmt_short(actual)), p_status); y = y + 1
  if w >= 20 then ui.progress(mon, 2, y, math.max(8, w - 3), math.min(100, p_pct) / 100, p_status) end; y = y + 1
  write_line(mon, y, string.format("Master %s -> %s RF/t", fmt(model.target_percent, 1, "%"), fmt_short(target)), "text"); y = y + 1
  write_line(mon, y, string.format("Cap %s %s %.1f%%", fmt_short(capacity), model.capacity_ready and "lock" or "learn", cap_pct), capacity_status(model)); y = y + 1
  if not model.capacity_ready and y <= h - 1 then
    local REQUIRED_SAMPLES = 3
    local stable_t = num(model.capacity_stable_turbines, 0)
    -- total_t: Priorität: capacity_total_turbines → turbines-Liste → configured_turbines
    local turb_list = (snapshot and snapshot.turbines) or {}
    local total_t  = math.max(1,
      num(model.capacity_total_turbines, 0) > 0 and num(model.capacity_total_turbines, 0)
      or #turb_list > 0 and #turb_list
      or num(model.configured_turbines, 1))
    local samples  = num(model.capacity_stable_samples, 0)
    local turbine_pct = math.min(1, stable_t / total_t)
    local sample_pct  = math.min(1, samples / REQUIRED_SAMPLES)
    local learn_pct   = (turbine_pct * 0.5) + (sample_pct * 0.5)
    local learn_status = samples >= REQUIRED_SAMPLES and "OK"
                      or stable_t >= total_t and "LIMITED" or "WARN"
    write_line(mon, y, string.format("Lrn T:%d/%d S:%d/%d %d%%",
      stable_t, total_t, samples, REQUIRED_SAMPLES,
      math.floor(learn_pct * 100)), learn_status); y = y + 1
    if w >= 20 and y <= h - 1 then
      ui.progress(mon, 2, y, math.max(8, w - 3), learn_pct, learn_status); y = y + 1
    end
  end
  write_line(mon, y, string.format("RPM %s/%s Steam %s", fmt_short(snapshot.avg_rpm), fmt_short(model.target_rpm), fmt_short(snapshot.steam_amount)), "muted"); y = y + 1
  write_line(mon, y, string.format("R:%d T:%d Cmd:%s M:%s", reactors, turbines, tostring(model.last_command or "-"), tostring(model.master_age or "-")), "text"); y = y + 1

  -- ── Turbinen: zwei Spalten nebeneinander ──────────────────────────────
  -- Turbinen-Header und -Zeilen ab y, zwei gleichbreite Spalten.
  -- Spalte A: x=2, Spalte B: x=2+col_w+1
  -- ID-Anzeige: laufende Nummer (1..N), nicht der Peripheral-Name
  local list = snapshot.turbines or {}
  if #list > 0 then
    local col_w   = math.floor((w - 3) / 2)
    local col_b_x = 2 + col_w + 1
    -- per_col: erste Hälfte (aufgerundet) in Spalte A, Rest in Spalte B
    local per_col = math.ceil(#list / 2)

    -- Header
    local hdr = string.format("%-3s %-4s %-4s %-2s", "T", "RPM", "RF/t", "C")
    ui.text(mon, 2,       y, hdr:sub(1, col_w), colors.get("text"), colors.get("background"))
    ui.text(mon, col_b_x, y, hdr:sub(1, col_w), colors.get("text"), colors.get("background"))
    y = y + 1

    for idx, t in ipairs(list) do
      -- Spalte und Zeile bestimmen
      local in_col_b = idx > per_col
      local row      = in_col_b and (idx - per_col) or idx
      local tx       = in_col_b and col_b_x or 2
      local ty       = y + row - 1
      if ty <= h then
        -- Laufende Nummer statt Peripheral-Name
        local id_s = tostring(idx)
        local txt  = string.format("%-3s %-4s %-4s %-2s",
          id_s, fmt_short(t.rpm), fmt_short(t.energy),
          t.inductor and "ON" or "OF")
        local st = (t.bound == false) and "WARNING"
                or (t.inductor and "OK" or "OFFLINE")
        ui.text(mon, tx, ty, txt:sub(1, col_w), colors.get(st), colors.get("background"))
      end
    end
  end
end

local function render_turbines(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health = model.health and model.health.status or "OFFLINE"
  local _, h = clear_and_title(mon, "RT TURBINES", health)
  local y = render_compact_header(mon, model, "Turbines")
  local turbines = snapshot.turbines or {}
  write_line(mon, y, string.format("Total %d  Out %s  AvgRPM %s", #turbines, fmt_short(snapshot.actual_output), fmt_short(snapshot.avg_rpm)), "text"); y = y + 1
  table_header(mon, y, { "ID", "RPM", "Flow", "RF/t", "C" }, { 8, 7, 7, 8, 4 }); y = y + 1
  local max_rows = math.max(0, h - y)
  local shown = math.min(#turbines, max_rows)
  for i = 1, shown do
    local t = turbines[i]
    local status = (t.bound == false) and "WARNING" or "OK"
    if t.rpm and num(model.target_rpm, 0) > 0 and math.abs(num(t.rpm, 0) - num(model.target_rpm, 0)) > 40 then status = "WARNING" end
    table_row(mon, y, { tostring(t.id or i), fmt_short(t.rpm), fmt_short(t.flow), fmt_short(t.energy), t.inductor and "ON" or "OFF" }, { 8, 7, 7, 8, 4 }, status, 5)
    y = y + 1
  end
  if #turbines == 0 then write_line(mon, y, "Keine Turbinen sichtbar", "WARNING")
  elseif #turbines > shown and y <= h then write_line(mon, y, "... +" .. tostring(#turbines - shown) .. " more", "muted") end
end

local function render_reactors(mon, model)
  local snapshot = monitor_snapshot(model) or {}
  local health = model.health and model.health.status or "OFFLINE"
  local _, h = clear_and_title(mon, "RT REACTORS", health)
  local y = render_compact_header(mon, model, "Reactors")
  local reactors = snapshot.reactors or {}
  write_line(mon, y, string.format("Total %d  AvgT %sC  Steam %s", #reactors, fmt_short(snapshot.avg_temp), fmt_short(snapshot.steam_amount)), "text"); y = y + 1
  table_header(mon, y, { "ID", "Temp", "Rod", "Act", "Steam" }, { 8, 8, 6, 5, 8 }); y = y + 1
  local max_rows = math.max(0, h - y)
  local shown = math.min(#reactors, max_rows)
  for i = 1, shown do
    local r = reactors[i]
    local status = (r.bound == false) and "WARNING" or (r.active == false and "LIMITED" or "OK")
    table_row(mon, y, { tostring(r.id or i), fmt_short(r.temperature), fmt_short(r.rods), r.active and "ON" or "OFF", fmt_short(r.steam_production) }, { 8, 8, 6, 5, 8 }, status, 4)
    y = y + 1
  end
  if #reactors == 0 then write_line(mon, y, "Keine Reaktoren sichtbar", "WARNING")
  elseif #reactors > shown and y <= h then write_line(mon, y, "... +" .. tostring(#reactors - shown) .. " more", "muted") end
end

local function render_diagnostics(mon, model)
  local health = model.health and model.health.status or "OFFLINE"
  local w, h = clear_and_title(mon, "RT DIAG", health)
  local y = render_compact_header(mon, model, "Diag")
  local rows = {
    { "Master", tostring(model.master_state or "?") .. " age " .. tostring(model.master_age or "-"), master_status(model) },
    { "Comms", string.format("tx/rx %d/%d", model.metrics.sent or 0, model.metrics.received or 0), "OK" },
    { "Retry", string.format("r%d d%d", model.metrics.retries or 0, model.metrics.dropped or 0), ((model.metrics.dropped or 0) > 0) and "WARNING" or "OK" },
    { "Set", string.format("%s / %s", fmt_short(model.target_power), fmt(model.target_percent, 1, "%")), "LIMITED" },
    { "RPM", fmt_short(model.target_rpm) .. " steam " .. fmt_short(model.target_steam), "LIMITED" },
    { "Cap", fmt_short(model.capacity_max) .. " " .. tostring(model.capacity_ready and "locked" or "learn"), capacity_status(model) },
    { "Cmd", tostring(model.last_command or "none") .. " " .. tostring(model.last_command_ts or "-"), "OK" },
    { "Scan", tostring(model.last_scan or "-"), "OK" }
  }
  for _, r in ipairs(rows) do
    if y > h then break end
    ui.text(mon, 2, y, pad(r[1], 7), colors.get(r[3]), colors.get("background"))
    ui.text(mon, 9, y, fit(r[2], math.max(1, w - 10)), colors.get("text"), colors.get("background"))
    y = y + 1
  end
  local alerts = model.local_alerts or {}
  if y <= h and #alerts > 0 then
    write_line(mon, y, "Alerts:", "WARNING"); y = y + 1
    local shown = math.min(#alerts, math.max(0, h - y + 1))
    for i = 1, shown do
      local a = alerts[i]
      write_line(mon, y, tostring(a.severity or "INFO") .. " " .. tostring(a.title or a.message or a.code or "alert"), a.severity == "CRITICAL" and "EMERGENCY" or "WARNING")
      y = y + 1
    end
    if #alerts > shown and y <= h then write_line(mon, y, "... +" .. tostring(#alerts - shown) .. " alerts", "muted") end
  end
  if utils then
    support_ui_pages.render_log_mode_button(mon, utils, 1, h, w - 2)
  end
end

function M.collect_reactor_temp_stats(devices, reactor_adapter, log_prefix)
  local min_temp, max_temp, sum_temp, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    local temp = type(info) == "table" and info.temperature or nil
    if type(temp) == "number" then
      count = count + 1; sum_temp = sum_temp + temp
      if not min_temp or temp < min_temp then min_temp = temp end
      if not max_temp or temp > max_temp then max_temp = temp end
    end
  end
  return min_temp, max_temp, count > 0 and (sum_temp / count) or nil
end

function M.collect_turbine_rpm_stats(devices, read_turbine_rpm, get_device_caps)
  local min_rpm, max_rpm, sum_rpm, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local rpm = read_turbine_rpm(entry.peripheral, get_device_caps("turbine", entry.id))
    if type(rpm) == "number" then
      count = count + 1; sum_rpm = sum_rpm + rpm
      if not min_rpm or rpm < min_rpm then min_rpm = rpm end
      if not max_rpm or rpm > max_rpm then max_rpm = rpm end
    end
  end
  return min_rpm, max_rpm, count > 0 and (sum_rpm / count) or nil
end

function M.build_turbine_status_details(devices, turbine_adapter, read_turbine_rpm, read_turbine_flow, get_device_caps, log_prefix)
  local list, total_output = {}, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local turbine = entry.peripheral
    local caps = get_device_caps("turbine", entry.id)
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function" and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = { id = entry.id, bound = entry.bound ~= false, rpm = info.rpm or read_turbine_rpm(turbine, caps), flow = info.flow or read_turbine_flow(turbine, caps), energy = energy, active = info.active, inductor = info.coil_engaged }
  end
  return list, total_output
end

function M.build_reactor_status_details(devices, reactor_adapter, log_prefix)
  local list = {}
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local rods = info.control_rod_level
    if rods == nil and reactor_adapter and type(reactor_adapter.read_control_rods) == "function" and entry and entry.name then rods = reactor_adapter.read_control_rods(entry.name, log_prefix) end
    list[#list + 1] = { id = entry.id, bound = entry.bound ~= false, temperature = info.temperature, fuel = info.fuel, energy_stored = info.energy_stored, energy_output = info.energy_output, waste = info.waste, active = info.active, is_actively_cooled = info.is_actively_cooled, rods = rods, steam_production = info.steam, coolant_amount = info.coolant_amount, coolant_amount_max = info.coolant_amount_max, coolant_filled_percentage = info.coolant_filled_percentage }
  end
  return list
end

function M.update_status_snapshot(ctx)
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary() or {}
  local min_temp, max_temp, avg_temp = M.collect_reactor_temp_stats(ctx.devices, ctx.reactor_adapter, ctx.log_prefix)
  local min_rpm, max_rpm, avg_rpm = M.collect_turbine_rpm_stats(ctx.devices, ctx.read_turbine_rpm, ctx.get_device_caps)
  local turbines, actual_output = M.build_turbine_status_details(ctx.devices, ctx.turbine_adapter, ctx.read_turbine_rpm, ctx.read_turbine_flow, ctx.get_device_caps, ctx.log_prefix)
  local capacity = ctx.capacity_learning or {}
  ctx.last_status_snapshot = { ts = os.epoch("utc"), node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id, summary = summary, min_temp = min_temp, max_temp = max_temp, avg_temp = avg_temp, min_rpm = min_rpm, max_rpm = max_rpm, avg_rpm = avg_rpm, steam_amount = ctx.get_available_steam(), target_power = ctx.targets and ctx.targets.power or nil, target_percent = ctx.targets and ctx.targets.power_percent or nil, target_rpm = ctx.targets and ctx.targets.rpm or nil, target_steam = ctx.targets and ctx.targets.steam or nil, actual_output = actual_output, capacity_max = capacity.max_output or (ctx.targets and ctx.targets.capacity_max) or 0, capacity_ready = capacity.locked == true, capacity_source = capacity.reason or (ctx.targets and ctx.targets.capacity_source) or "unknown", capacity_stable_samples  = capacity.stable_samples or 0,
                capacity_stable_turbines = capacity.stable_turbines_last or 0,
                capacity_total_turbines  = capacity.total_turbines_last or 0, reactors = M.build_reactor_status_details(ctx.devices, ctx.reactor_adapter, ctx.log_prefix), turbines = turbines }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil; M.last_monitor_update = 0
  local monitor, name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then return nil, name_or_err end
  return monitor, name_or_err
end

function M.update(monitor, ctx)
  if not monitor then return ctx.last_status_snapshot end
  local now = os.epoch("utc")
  if now - M.last_monitor_update < (ctx.config.monitor_interval * 1000) then return ctx.last_status_snapshot end
  M.last_monitor_update = now
  local snapshot = M.update_status_snapshot(ctx)
  local health_payload = ctx.build_health_payload()
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local metrics = comms_diag.metrics or {}
  local master_state, master_age = "UNKNOWN", "n/a"
  for _, peer in pairs(comms_diag.peers or {}) do
    if peer.role == ctx.constants.roles.MASTER then master_state = peer.down and "DOWN" or "OK"; master_age = peer.age and (math.floor(peer.age) .. "s") or "n/a"; break end
  end
  local node_id = snapshot and snapshot.node_id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[node_id] or nil
  local targets = ctx.targets or {}
  local model = { snapshot = { snapshot = snapshot, local_alerts = alert_payload and alert_payload.critical or 0 }, health = health_payload, summary = summary, comms = comms_diag, metrics = metrics, master_state = master_state, master_age = master_age, last_scan = ctx.devices.last_scan_ts and (math.floor((now - ctx.devices.last_scan_ts) / 1000) .. "s") or "n/a", last_command = ctx.last_command, last_command_ts = ctx.last_command_ts and (math.floor((now - ctx.last_command_ts) / 1000) .. "s") or "n/a", local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0, node_id = node_id, current_state = ctx.current_state, node_state = ctx.node_state_machine and ctx.node_state_machine:state() or ctx.current_state, configured_reactors = ctx.configured_reactors, configured_turbines = ctx.configured_turbines, target_power = targets.power, target_percent = targets.power_percent, target_rpm = targets.rpm or (ctx.get_target_rpm and ctx.get_target_rpm()), target_steam = targets.steam, capacity_max = snapshot and snapshot.capacity_max or 0, capacity_ready = snapshot and snapshot.capacity_ready or false, capacity_source = snapshot and snapshot.capacity_source or "unknown", capacity_stable_samples  = snapshot and snapshot.capacity_stable_samples or 0,
                capacity_stable_turbines = snapshot and snapshot.capacity_stable_turbines or 0,
                capacity_total_turbines  = snapshot and snapshot.capacity_total_turbines or 0, binding = ctx.binding, build_label = ctx.build_label or ctx.manifest_id or ctx.release_id }
  if not M.monitor_router then
    M.monitor_router = ui_router.new({ pages = { { name = "Overview", render = render_overview }, { name = "Turbines", render = render_turbines }, { name = "Reactors", render = render_reactors }, { name = "Diagnostics", render = render_diagnostics } }, key_prev = { [keys.left] = true, [keys.pageUp] = true }, key_next = { [keys.right] = true, [keys.pageDown] = true } })
  end
  M.last_monitor = monitor
  M.monitor_router:render(monitor, model)
  return snapshot
end

function M.handle_input(event)
  if M.monitor_router then M.monitor_router:handle_input(event) end
  -- Log mode buttons on Diagnostics page (bottom row of monitor)
  if utils and event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
    local page = M.monitor_router and M.monitor_router:current()
    if page and page.name == "Diagnostics" and M.last_monitor then
      local _, h = ui.getSize(M.last_monitor)
      if h then
        support_ui_pages.handle_log_mode_touch(event[3], event[4], h, utils, 1)
      end
    end
  end
end

return M
