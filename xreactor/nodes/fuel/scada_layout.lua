-- nodes/fuel/scada_layout.lua
--
-- Native fixed-size FUEL SCADA presentation for an 8x6 Advanced Monitor at
-- TextScale 1.0 => 82x40 cells.
--
-- Design goals of this revision:
--   * larger/readable text and stronger panel framing
--   * 16 Overview slots remain visible, including NICHT KONFIGURIERT slots
--   * page-local navigation buttons are smaller than the old 18/19x3 blocks
--   * all visible controls publish the exact rectangle they draw
--   * presentation only: no logistics/control/safety/persistence logic

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local REACTORS_PER_PAGE = 16
local REACTOR_ROWS_PER_COLUMN = 8

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function exact_size(mon)
  if not mon or type(mon.getSize) ~= "function" then return false, 0, 0 end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0 end
  return w == TARGET_W and h == TARGET_H, w, h
end

local function render_size_error(mon, title)
  local ok, w, h = pcall(mon.getSize)
  w, h = ok and w or TARGET_W, ok and h or TARGET_H
  mux.clear(mon)
  mux.header(mon, {
    title = title or "FUEL SCADA", node_id = "FUEL", page = "82x40",
    status = "WARNING", icon = "warning",
  })
  local box_w = math.max(20, math.min(w - 4, 72))
  local box_x = math.max(2, math.floor((w - box_w) / 2) + 1)
  mux.card(mon, box_x, 7, box_w, 14, {
    title = "MONITOR-GROESSE FALSCH", status = "WARNING", icon = "warning",
  })
  mux.text(mon, box_x + 2, 10,
    mux.fit("FUEL ist fest fuer 82x40 / TextScale 1.0 gebaut.", box_w - 4),
    colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, box_x + 2, 13,
    mux.fit("Erkannt: " .. tostring(w) .. "x" .. tostring(h), box_w - 4),
    colorset.get("text"), colorset.get("background"))
  return false
end

local function short(value, suffix)
  local n = tonumber(value)
  if not n then return "-" end
  if math.abs(n) >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if math.abs(n) >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function reactor_key(reactor)
  if type(reactor) ~= "table" then return "muted" end
  if type(reactor.fuel_pct) == "number" and reactor.fuel_pct < 10 then return "EMERGENCY" end
  local state = reactor.delivery_state or reactor.operational_state or "MISSING"
  if state == "READY" then return "OK" end
  if state == "DELIVERING" or state == "REQUESTING" then return "LIMITED" end
  return "WARNING"
end

local function reactor_state_text(reactor)
  if type(reactor) ~= "table" then return "NICHT KONFIGURIERT" end
  local state = tostring(reactor.delivery_state or reactor.operational_state or "MISSING")
  if reactor.fuel_data_state == "STALE" then return "DATEN ALT" end
  if reactor.fuel_data_state == "MISSING" then return "DATEN FEHLEN" end
  if state == "READY" then return "BEREIT" end
  if state == "DELIVERING" then return "LIEFERUNG" end
  if state == "REQUESTING" then return "ANFORDERUNG" end
  if state == "BLOCKED" then return "BLOCKIERT" end
  return state
end

local function fuel_pct(reactor)
  if type(reactor) == "table" and type(reactor.fuel_pct) == "number" then
    return clamp(reactor.fuel_pct, 0, 100)
  end
  return nil
end

local function route_count(reactor)
  if type(reactor) ~= "table" then return 0 end
  if type(reactor.path) == "table" then return #reactor.path end
  if type(reactor.route) == "table" then return #reactor.route end
  return tonumber(reactor.path_len or reactor.route_len) or 0
end

local function count_reactors(reactors)
  local out = { ready = 0, delivering = 0, warning = 0, emergency = 0 }
  for _, reactor in ipairs(reactors or {}) do
    local key = reactor_key(reactor)
    if key == "OK" then out.ready = out.ready + 1
    elseif key == "LIMITED" then out.delivering = out.delivering + 1
    elseif key == "EMERGENCY" then out.emergency = out.emergency + 1
    else out.warning = out.warning + 1 end
  end
  return out
end

local function draw_header(mon, model, title, page, should_clear)
  local ok, w, h = exact_size(mon)
  if not ok then return nil, nil, nil, render_size_error(mon, title) end
  if should_clear == true then mux.clear(mon) end
  local view = model.view_state or {}
  mux.header(mon, {
    title = title,
    node_id = model.node_id or "FUEL-?",
    page = page,
    status = view.severity or model.status or "WARNING",
    icon = "fuel",
  })
  return w, h, view, true
end

local function draw_operator_banner(mon, w, view)
  local key = view.severity or "WARNING"
  local title = tostring(view.title or view.code or "STATUS")
  local detail = tostring(view.detail or "")
  local text
  if key == "OK" then
    text = "SYSTEM BEREIT" .. (detail ~= "" and (" - " .. detail) or "")
  else
    text = title .. (detail ~= "" and (" - " .. detail) or "")
  end
  mux.banner(mon, 2, 4, w - 3, text, key, key == "OK" and "ok" or "warning")
end

local function draw_metric_cards(mon, w, payload, logistics, reactors)
  local reserve = tonumber(payload.reserve) or 0
  local minimum = tonumber(payload.minimum_reserve) or 0
  local margin = reserve - minimum
  local counts = count_reactors(reactors)
  local cw = 25
  local x1, x2, x3 = 2, 29, 56

  mux.metric_card(mon, x1, 6, cw, 5, {
    label = "RESERVE", value = short(reserve, "mB"),
    status = margin >= 0 and "OK" or "WARNING", icon = "storage",
  })
  mux.text(mon, x1 + 2, 9,
    mux.fit("MIN " .. short(minimum, "mB") .. "  " .. (margin >= 0 and "+" or "") .. short(margin, "mB"), cw - 4),
    colorset.get(margin >= 0 and "muted" or "WARNING"), colorset.get("background"))

  local fleet_status = (counts.warning + counts.emergency) == 0 and "OK" or "WARNING"
  mux.metric_card(mon, x2, 6, cw, 5, {
    label = "REAKTOREN", value = string.format("%d / %d BEREIT", counts.ready, #reactors),
    status = fleet_status, icon = "reactor",
  })
  mux.text(mon, x2 + 2, 9,
    mux.fit(string.format("LIEF %d  WARN %d", counts.delivering, counts.warning + counts.emergency), cw - 4),
    colorset.get(fleet_status == "OK" and "muted" or "WARNING"), colorset.get("background"))

  local logistics_on = logistics.enabled == true
  mux.metric_card(mon, x3, 6, 25, 5, {
    label = "LOGISTIK", value = logistics_on and "AKTIV" or "AUS",
    status = logistics_on and "OK" or "LIMITED", icon = "output",
  })
  mux.text(mon, x3 + 2, 9,
    mux.fit("EXPORT " .. tostring(logistics.export_chest or "NICHT GESETZT"), 21),
    colorset.get(logistics.export_chest and "muted" or "WARNING"), colorset.get("background"))
end

-- Two rows per slot. Missing entries are deliberately visible as quiet,
-- non-touchable placeholders so the operator always sees all 16 positions.
local function draw_reactor_slot(mon, x, y, w, reactor, absolute_index)
  if type(reactor) ~= "table" then
    mux.text(mon, x, y,
      mux.fit(string.format("%02d  NICHT KONFIGURIERT", absolute_index), w),
      colorset.get("muted"), colorset.get("background"))
    mux.text(mon, x + 2, y + 1, mux.fit(string.rep("-", math.max(3, w - 4)), w - 2),
      colorset.get("muted"), colorset.get("background"))
    return
  end

  local key = reactor_key(reactor)
  local pct = fuel_pct(reactor)
  local pct_text = pct and string.format("%d%%", math.floor(pct + 0.5)) or "--%"
  local state = reactor_state_text(reactor)
  local right = pct_text .. " " .. state
  local label = tostring(reactor.label or reactor.reactor_id or ("Reaktor " .. tostring(absolute_index)))
  local left_w = math.max(8, w - #right - 2)
  mux.text(mon, x, y,
    mux.fit(string.format("%02d %s", absolute_index, label), left_w),
    colorset.get(key), colorset.get("background"))
  mux.text(mon, x + w - #right, y, right,
    colorset.get(key), colorset.get("background"))

  local bar_w = math.max(10, math.min(19, w - 14))
  mux.outlined_progress(mon, x + 2, y + 1, bar_w, (pct or 0) / 100, key, nil)
  local age = reactor.fuel_age_s ~= nil and (tostring(reactor.fuel_age_s) .. "s") or "--"
  mux.text(mon, x + bar_w + 3, y + 1,
    mux.fit(string.format("R%d A%s", route_count(reactor), age), math.max(5, w - bar_w - 3)),
    colorset.get("muted"), colorset.get("background"))
end

local function draw_overview_reactors(mon, w, reactors, state, view)
  local total_pages = math.max(1, math.ceil(math.max(#reactors, 1) / REACTORS_PER_PAGE))
  state.overview_page = clamp(state.overview_page, 1, total_pages)
  local first = (state.overview_page - 1) * REACTORS_PER_PAGE + 1
  local last_configured = math.min(#reactors, first + REACTORS_PER_PAGE - 1)

  mux.section(mon, 2, 12, w - 3,
    string.format("REAKTORFLOTTE  %d-%d  |  %d KONFIGURIERT",
      first, first + REACTORS_PER_PAGE - 1, #reactors),
    #reactors > 0 and "LIMITED" or "WARNING", "reactor")

  state.overview_prev, state.overview_next = nil, nil
  local gap = 2
  local col_w = 39
  local left_x, right_x = 2, 43
  local first_y = 14

  for slot = 1, REACTORS_PER_PAGE do
    local idx = first + slot - 1
    local col = slot > REACTOR_ROWS_PER_COLUMN and 2 or 1
    local row = (slot - 1) % REACTOR_ROWS_PER_COLUMN
    local x = col == 1 and left_x or right_x
    draw_reactor_slot(mon, x, first_y + row * 2, col_w, reactors[idx], idx)
  end

  if #reactors == 0 then
    mux.text(mon, 3, 31,
      mux.fit("HINWEIS: Router oeffnen und Reaktoren einlernen.", w - 5),
      colorset.get("WARNING"), colorset.get("background"))
  elseif view.action then
    mux.text(mon, 3, 31, mux.fit("HINWEIS: " .. tostring(view.action), w - 5),
      colorset.get(view.severity == "OK" and "muted" or "WARNING"), colorset.get("background"))
  end

  if total_pages > 1 then
    local nav_y = 33
    local btn_w = 13
    if state.overview_page > 1 then
      state.overview_prev = mux.button(mon, 3, nav_y, btn_w, "<< REAKTOR", "LIMITED", 2)
    end
    if state.overview_page < total_pages then
      state.overview_next = mux.button(mon, 67, nav_y, btn_w, "REAKTOR >>", "LIMITED", 2)
    end
    local txt = string.format("SEITE %d/%d  BIS %d", state.overview_page, total_pages, last_configured)
    mux.text(mon, math.floor((w - #txt) / 2) + 1, nav_y + 1, txt,
      colorset.get("muted"), colorset.get("background"))
  end
end

local function last_delivery_text(reactor)
  if not reactor.last_item then return "NOCH KEINE LIEFERUNG" end
  return tostring(reactor.last_item) .. " (" .. tostring(reactor.last_element or "?") .. ")"
end

local function draw_details(mon, model, should_clear, state)
  local w, _, view, ok = draw_header(mon, model, "FUEL NODE - DETAILS", "2/4", should_clear)
  if not ok then return false end
  local logistics = (model.payload or {}).logistics or {}
  local reactors = logistics.reactors or {}

  state.details_prev, state.details_next = nil, nil
  if #reactors == 0 then
    mux.banner(mon, 2, 4, w - 3, "KEINE REAKTOREN KONFIGURIERT", "WARNING", "warning")
    mux.warning_box(mon, 5, 10, 73, {
      "Router oeffnen und Reaktor einlernen.",
      "Export-Kiste und VALVE-Route danach pruefen.",
    }, "WARNING")
    return true
  end

  state.details_index = clamp(state.details_index, 1, #reactors)
  local reactor = reactors[state.details_index]
  local key = reactor_key(reactor)
  local label = tostring(reactor.label or reactor.reactor_id or "?")

  mux.banner(mon, 2, 4, w - 3,
    string.format("REAKTOR %d / %d - %s", state.details_index, #reactors, label), key, "reactor")

  local nav_w = 13
  if state.details_index > 1 then
    state.details_prev = mux.button(mon, 3, 5, nav_w, "<< REAKTOR", "LIMITED", 2)
  end
  if state.details_index < #reactors then
    state.details_next = mux.button(mon, 67, 5, nav_w, "REAKTOR >>", "LIMITED", 2)
  end
  local center = label .. "  " .. tostring(state.details_index) .. "/" .. tostring(#reactors)
  mux.text(mon, math.floor((w - #center) / 2) + 1, 6, mux.fit(center, 34),
    colorset.get("text"), colorset.get("background"))

  local left_w = 43
  local right_x = 47
  local right_w = 34
  mux.card(mon, 2, 8, left_w, 7, { title = "FUEL", status = key, icon = "fuel" })
  local pct = fuel_pct(reactor)
  mux.text(mon, 4, 10,
    pct and string.format("%d%%", math.floor(pct + 0.5)) or "--%",
    colorset.get(key), colorset.get("background"))
  mux.outlined_progress(mon, 4, 12, left_w - 4, (pct or 0) / 100, key, nil)
  mux.text(mon, 4, 13,
    mux.fit("DATA " .. tostring(reactor.fuel_data_state or "MISSING") ..
      "  ALTER " .. tostring(reactor.fuel_age_s or "--") .. "s", left_w - 4),
    colorset.get(reactor.fuel_data_state == "FRESH" and "muted" or "WARNING"),
    colorset.get("background"))

  mux.card(mon, right_x, 8, right_w, 7, { title = "STATUS", status = key, icon = "ok" })
  mux.text(mon, right_x + 2, 10, mux.fit(reactor_state_text(reactor), right_w - 4),
    colorset.get(key), colorset.get("background"))
  mux.text(mon, right_x + 2, 12, mux.fit("ROUTE " .. tostring(reactor.route_state or "?"), right_w - 4),
    colorset.get("muted"), colorset.get("background"))
  mux.text(mon, right_x + 2, 13, mux.fit("QUELLE " .. tostring(reactor.fuel_source or "-"), right_w - 4),
    colorset.get("muted"), colorset.get("background"))

  local mw = 19
  local mx = { 2, 22, 42, 62 }
  local request = reactor.request_below and string.format("%d%%", math.floor(reactor.request_below * 100 + 0.5)) or "?"
  local fill = reactor.fill_amount and tostring(reactor.fill_amount) or "?"
  local min_me = reactor.min_in_me and tostring(reactor.min_in_me) or "?"
  local cooldown = reactor.resupply_cooldown_s and (tostring(math.floor(reactor.resupply_cooldown_s)) .. "s") or "?"
  local metric_data = {
    { label = "NACHFUELLEN", value = request },
    { label = "LIEFERMENGE", value = fill .. " Items" },
    { label = "ME MINIMUM", value = min_me .. " Items" },
    { label = "ABKLINGZEIT", value = cooldown },
  }
  for i = 1, 4 do
    mux.metric_card(mon, mx[i], 16, mw, 5, {
      label = metric_data[i].label, value = metric_data[i].value,
      status = "OK", icon = "config",
    })
  end

  mux.card(mon, 2, 22, 46, 6, {
    title = "ROUTE", status = route_count(reactor) > 0 and "OK" or "WARNING", icon = "network",
  })
  local path_len = route_count(reactor)
  mux.text(mon, 4, 24,
    path_len > 0 and (tostring(path_len) .. " Ventile konfiguriert") or "KEINE ROUTE",
    colorset.get(path_len > 0 and "OK" or "WARNING"), colorset.get("background"))
  if path_len > 0 and type(reactor.path) == "table" then
    local ids = {}
    for i = 1, math.min(path_len, 5) do ids[#ids + 1] = tostring(reactor.path[i]) end
    mux.text(mon, 4, 26,
      mux.fit(table.concat(ids, " > ") .. (path_len > 5 and " > ..." or ""), 42),
      colorset.get("muted"), colorset.get("background"))
  end

  mux.card(mon, 50, 22, 31, 6, {
    title = "LETZTE LIEFERUNG", status = reactor.last_item and "OK" or "LIMITED", icon = "fuel",
  })
  mux.text(mon, 52, 24, mux.fit(last_delivery_text(reactor), 27),
    colorset.get(reactor.last_item and "text" or "muted"), colorset.get("background"))
  if reactor.last_delivery_age_s ~= nil then
    mux.text(mon, 52, 26, mux.fit("vor " .. tostring(reactor.last_delivery_age_s) .. "s", 27),
      colorset.get("muted"), colorset.get("background"))
  end

  mux.card(mon, 2, 29, 79, 7, { title = "SCADA DATEN", status = view.severity or key, icon = "network" })
  mux.data_row(mon, 4, 31, 75, {
    label = "REACTOR ID", value = tostring(reactor.reactor_id or "MISSING"),
    status = reactor.reactor_id and "text" or "WARNING", icon = "reactor",
  })
  mux.data_row(mon, 4, 32, 75, {
    label = "FUEL SOURCE", value = tostring(reactor.fuel_source or "-"), status = "text", icon = "network",
  })
  mux.data_row(mon, 4, 33, 75, {
    label = "VIEW STATE", value = tostring(view.code or model.status or "?"),
    status = view.severity or "text", icon = "warning",
  })
  mux.data_row(mon, 4, 34, 75, {
    label = "ROUTE", value = tostring(path_len) .. " Ventile", status = path_len > 0 and "OK" or "WARNING", icon = "network",
  })
  return true
end

local function draw_diagnostics(mon, model, should_clear)
  local w, _, view, ok = draw_header(mon, model, "FUEL NODE - DIAGNOSTICS", "3/4", should_clear)
  if not ok then return false end
  local payload = model.payload or {}
  local summary = model.summary or {}
  local logistics = payload.logistics or {}
  local reactors = logistics.reactors or {}
  local valve = payload.valve_summary or {}
  local alerts = model.local_alerts or {}
  local uidiag = model.ui_diagnostics or {}

  local top = {
    { label = "SYSTEM", value = tostring(view.code or model.status or "?"), status = view.severity or "WARNING", icon = "ok" },
    { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
    { label = "HARDWARE", value = logistics.bridge and "OK" or "PRUEFEN", status = logistics.bridge and "OK" or "WARNING", icon = "config" },
    { label = "UI", value = (uidiag.error_count or 0) == 0 and "OK" or "FEHLER", status = (uidiag.error_count or 0) == 0 and "OK" or "WARNING", icon = "network" },
  }
  for i, item in ipairs(top) do
    mux.metric_card(mon, 2 + (i - 1) * 20, 5, 19, 5, item)
  end

  mux.card(mon, 2, 11, 38, 14, { title = "KNOTEN STATUS", status = "LIMITED", icon = "network" })
  local left_rows = {
    { "ROLLE", "FUEL" },
    { "MASTER", tostring(model.master_state or "?") },
    { "REGISTRY", string.format("%d total / %d missing", tonumber(summary.total) or 0, tonumber(summary.missing) or 0) },
    { "REAKTOREN", tostring(#reactors) },
    { "VALVES", string.format("%d total / %d off", tonumber(valve.total) or 0, tonumber(valve.offline) or 0) },
    { "ALARME", tostring(#alerts) },
    { "LAST SCAN", tostring(model.last_scan or "-") },
    { "COMMAND", tostring(model.last_command or "none") },
  }
  for i, row in ipairs(left_rows) do
    mux.data_row(mon, 4, 12 + i, 34, { label = row[1], value = row[2], status = "text", icon = "network" })
  end

  mux.card(mon, 42, 11, 39, 14, {
    title = "DATEN / UI", status = (uidiag.error_count or 0) == 0 and "OK" or "WARNING", icon = "network",
  })
  local right_rows = {
    { "VIEW", tostring(view.code or "?") },
    { "RENDER ERR", tostring(uidiag.error_count or 0) },
    { "FRAMES", string.format("%d/%d", tonumber(uidiag.frames_committed) or 0, tonumber(uidiag.frames_requested) or 0) },
    { "SKIPPED", tostring(uidiag.frames_skipped or 0) },
    { "TOUCH", tostring(uidiag.pointer_events_received or 0) },
    { "MODEL", tostring(uidiag.model_builds or 0) },
    { "RT FRESH", tostring((logistics.fuel_data_summary or {}).fresh or 0) },
    { "RT STALE/MISS", string.format("%d/%d", tonumber((logistics.fuel_data_summary or {}).stale) or 0, tonumber((logistics.fuel_data_summary or {}).missing) or 0) },
  }
  for i, row in ipairs(right_rows) do
    mux.data_row(mon, 44, 12 + i, 35, { label = row[1], value = row[2], status = "text", icon = "network" })
  end

  mux.card(mon, 2, 26, 79, 10, { title = "FUEL / HARDWARE", status = logistics.bridge and "OK" or "WARNING", icon = "fuel" })
  mux.data_row(mon, 4, 28, 75, {
    label = "ME BRIDGE", value = tostring(logistics.bridge or "MISSING"),
    status = logistics.bridge and "OK" or "WARNING", icon = "storage",
  })
  mux.data_row(mon, 4, 29, 75, {
    label = "EXPORT-KISTE", value = tostring(logistics.export_chest or "NICHT GESETZT"),
    status = logistics.export_chest and "OK" or "WARNING", icon = "output",
  })
  local families = logistics.fuel_families or {}
  local y = 31
  for i = 1, math.min(#families, 4) do
    local fam = families[i]
    mux.data_row(mon, 4, y, 75, {
      label = tostring(fam.element or "FUEL"),
      value = string.format("ING %d  BLK %d  SUM %d",
        tonumber(fam.ingot_amt) or 0, tonumber(fam.block_amt) or 0, tonumber(fam.total) or 0),
      status = (tonumber(fam.total) or 0) > 0 and "OK" or "LIMITED", icon = "fuel",
    })
    y = y + 1
  end
  return true
end

local function hit(button, x, y)
  return button and y >= button.y and y <= (button.y2 or button.y)
    and x >= button.x1 and x <= button.x2
end

function M.attach(instance, opts)
  if type(instance) ~= "table" then return instance end
  if instance._scada_fixed_layout_attached then return instance end
  instance._scada_fixed_layout_attached = true
  opts = opts or {}

  local state = {
    overview_page = 1,
    overview_prev = nil,
    overview_next = nil,
    details_index = 1,
    details_prev = nil,
    details_next = nil,
  }

  instance.render_overview = function(mon, model, should_clear)
    local w, _, view, ok = draw_header(mon, model, "FUEL NODE - OVERVIEW", "1/4", should_clear)
    if not ok then return false end
    local payload = model.payload or {}
    local logistics = payload.logistics or {}
    local reactors = logistics.reactors or {}
    draw_operator_banner(mon, w, view)
    draw_metric_cards(mon, w, payload, logistics, reactors)
    draw_overview_reactors(mon, w, reactors, state, view)
    return nil
  end

  instance.handle_overview_touch = function(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    if hit(state.overview_prev, x, y) then
      state.overview_page = math.max(1, state.overview_page - 1)
      return true
    end
    if hit(state.overview_next, x, y) then
      state.overview_page = state.overview_page + 1
      return true
    end
    return false
  end

  instance.render_details = function(mon, model, should_clear)
    draw_details(mon, model, should_clear, state)
    return nil
  end

  instance.handle_details_touch = function(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    if hit(state.details_prev, x, y) then
      state.details_index = math.max(1, state.details_index - 1)
      return true
    end
    if hit(state.details_next, x, y) then
      state.details_index = state.details_index + 1
      return true
    end
    return false
  end

  instance.render_diagnostics = function(mon, model, should_clear)
    draw_diagnostics(mon, model, should_clear)
    return nil
  end
  instance.handle_diagnostics_touch = function() return false end

  instance.get_completion_state = function()
    return {
      details_index = state.details_index,
      details_prev = state.details_prev,
      details_next = state.details_next,
      scada_overview_page = state.overview_page,
      scada_details_index = state.details_index,
      fixed_width = TARGET_W,
      fixed_height = TARGET_H,
    }
  end

  return instance
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.REACTORS_PER_PAGE = REACTORS_PER_PAGE
M.exact_size = exact_size

return M
