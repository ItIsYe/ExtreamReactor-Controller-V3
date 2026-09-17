local M = {}
local mux = require("core.mockup_ui")

local function short(value, suffix)
  local n = tonumber(value)
  if not n then return "n/a" end
  local a = math.abs(n)
  if a >= 1000000 then return string.format("%.1fM%s", n / 1000000, suffix or "") end
  if a >= 1000 then return string.format("%.1fk%s", n / 1000, suffix or "") end
  return string.format("%.0f%s", n, suffix or "")
end

local function age_text(seconds)
  if type(seconds) ~= "number" then return "n/a" end
  if seconds < 60 then return string.format("%ds", seconds) end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  return string.format("%dh", math.floor(seconds / 3600))
end

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon)
    local status = model.status or "OK"
    mux.clear(mon)
    mux.header(mon, { title = title, node_id = model.node_id or "RP-?", page = page, status = status, icon = icon or "recycle" })
    local w = ({ mon.getSize() })[1]
    if w >= 42 then
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING")
      mux.status_dot(mon, math.floor(w * 0.38), 3, tostring(model.status or "OK"), status)
      mux.status_dot(mon, math.floor(w * 0.70), 3, "FEED LINK", status)
    end
    return mon.getSize()
  end

  local function section_arrow(mon, x, y, w, title, status, icon)
    mux.section(mon, x, y, w, "> " .. title, status, icon)
  end

  local function overview(mon, model)
    local w, h = header(mon, model, "REPROCESSING NODE", "1/4", "recycle")
    local p = model.payload or {}
    local feed = p.feed or {}
    local req = p.requirements or {}

    local routes_total = tonumber(feed.target_count) or 0
    local feed_enabled = feed.enabled == true
    -- Feeding kann eingeschaltet sein und trotzdem nichts bewegen, wenn
    -- ME-Bridge/Sorter/Sorter-Kiste fehlen -- ready fasst genau das
    -- zusammen, damit die Bannerfarbe nicht faelschlich OK zeigt.
    local ready = req.me_bridge == true and req.sorter == true and req.sorter_chest_present == true
    local key = (feed_enabled and ready) and (model.status == "OK" and "OK" or "WARNING")
      or (feed_enabled and "WARNING" or "LIMITED")
    local banner
    if not feed_enabled then
      banner = "FEEDING AUS"
    elseif not ready then
      banner = "FEEDING AN, ABER NICHT BEREIT"
    else
      banner = "FEEDING AKTIV"
    end

    -- Auf einem Monitor, der groesser ist als das urspruengliche Referenz-
    -- Layout (~19 Content-Zeilen ab Zeile 5), blieb der untere Teil des
    -- Bildschirms schlicht leer -- alle Bloecke standen auf fixen
    -- Zeilennummern statt sich proportional zu verteilen. Gleiches Muster
    -- wie nodes/rt/mockup_pages.lua's render_overview(): scale bleibt bei
    -- 1.0 (Original-Abstaende) auf kleinen Monitoren, waechst nur wenn
    -- mehr Platz da ist.
    local content_top = 5
    local content_bottom = math.max(content_top + 19, h - 2)
    local content_h = content_bottom - content_top
    local scale = math.max(1.0, content_h / 19)
    local function y_at(offset) return content_top + math.floor(offset * scale) end

    mux.banner(mon, 2, y_at(0), w - 3, "> " .. banner, key, nil)

    if w >= 54 then
      local gap = 1
      local cw = math.floor((w - 4 - gap * 2) / 3)
      mux.metric_card(mon, 2, y_at(2), cw, 4, { label = "FEEDING", value = feed_enabled and "AN" or "AUS", status = feed_enabled and "OK" or "OFFLINE", icon = "config" })
      mux.metric_card(mon, 2 + cw + gap, y_at(2), cw, 4, { label = "ZIELE", value = tostring(routes_total), status = routes_total > 0 and "OK" or "WARNING", icon = "recycle" })
      mux.metric_card(mon, 2 + (cw + gap) * 2, y_at(2), cw, 4, { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" })
    else
      mux.kpi_strip(mon, 2, y_at(2), w - 3, {
        { label = "FEEDING", value = feed_enabled and "AN" or "AUS", status = feed_enabled and "OK" or "OFFLINE", icon = "config" },
        { label = "ZIELE", value = tostring(routes_total), status = routes_total > 0 and "OK" or "WARNING", icon = "recycle" },
        { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      })
    end

    section_arrow(mon, 2, y_at(7), w - 3, "NAECHSTER FEED", key, "recycle")
    local next_in = tonumber(feed.next_feed_in_s)
    mux.data_row(mon, 2, y_at(9), w - 3, {
      label = feed_enabled and (next_in and (tostring(next_in) .. "s") or "-") or "FEEDING AUS",
      value = "IN", status = feed_enabled and "text" or "OFFLINE", icon = "recycle",
    })

    if h >= 20 then
      local cw = math.floor((w - 5 - 3) / 4)
      local items = {
        { label = "LETZTES ZIEL", value = tostring(feed.last_target or "-"), status = "text", icon = "recycle" },
        { label = "LETZTER FEED", value = age_text(feed.last_feed_age_s), status = feed.last_feed_age_s and "OK" or "LIMITED", icon = "recycle" },
        { label = "GESAMT", value = short(feed.total_feeds), status = "text", icon = "recycle" },
        { label = "FEHLER", value = feed.last_error and "JA" or "NEIN", status = feed.last_error and "WARNING" or "OK", icon = "warning" },
      }
      for i, item in ipairs(items) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), y_at(12), cw, 4, item) end
    end

    if h >= 25 and feed.last_error then
      section_arrow(mon, 2, y_at(17), w - 3, "LETZTER FEHLER", "WARNING", "warning")
      mux.data_row(mon, 2, y_at(19), w - 3, { label = tostring(feed.last_error), value = "", status = "WARNING", icon = "warning" })
    end

    return mux.footer_nav(mon, h, w, { center = "REPROCESSING" })
  end

  local function details(mon, model)
    local w, h = header(mon, model, "REPROCESSING DETAILS", "2/4", "recycle")
    local p = model.payload or {}
    local feed = p.feed or {}
    local targets = feed.targets or {}

    local top = {
      { label = "ZIELE", value = tostring(#targets), status = #targets > 0 and "OK" or "WARNING", icon = "recycle" },
      { label = "GESAMT FEEDS", value = short(feed.total_feeds), status = "text", icon = "recycle" },
      { label = "LETZTER FEED", value = age_text(feed.last_feed_age_s), status = feed.last_feed_age_s and "OK" or "LIMITED", icon = "recycle" },
      { label = "FEEDING", value = feed.enabled and "AN" or "AUS", status = feed.enabled and "OK" or "OFFLINE", icon = "config" },
    }

    if w >= 54 then
      local cw = math.floor((w - 5 - 3) / 4)
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    section_arrow(mon, 2, 10, w - 3, "REPROCESSOR-ZIELE", "LIMITED", "recycle")
    local y = 12
    for i, t in ipairs(targets) do
      if y > h - 2 then break end
      local is_last = t.label == feed.last_target
      mux.data_row(mon, 2, y, w - 3, {
        label = string.format("%d. %s", i, tostring(t.label or "?")),
        value = tostring(t.color or "?"),
        status = is_last and "OK" or "text", icon = "recycle",
      })
      y = y + 1
    end

    if #targets == 0 then mux.warning_box(mon, 2, 12, w - 3, { "Keine Reprocessor-Ziele konfiguriert", "Im Router-UI hinzufuegen." }, "WARNING") end
    return mux.footer_nav(mon, h, w, { center = "PROCESS DETAILS" })
  end

  -- "Was wird gebraucht, was ist verbunden" -- fasst alle fuer die
  -- Reprocessor-Rotation noetigen Peripherals/Verbindungen (ME-Bridge,
  -- Sorter, SORTER-KISTE, Wireless-Modem, Monitor) in einer einzigen
  -- Liste zusammen, statt das aus Registry-/Feed-Einzelanzeigen
  -- zusammenraten zu muessen (main.lua's build_requirements()).
  local function append_requirement_rows(rows, req)
    if not req then return end
    local function add(label, ok, extra)
      local suffix = extra and extra ~= "" and (" (" .. tostring(extra) .. ")") or ""
      rows[#rows + 1] = { text = label .. ": " .. (ok and "OK" or "FEHLT") .. suffix, status = ok and "OK" or "WARNING" }
    end
    add("ME-BRIDGE", req.me_bridge, req.me_bridge_name)
    add("SORTER", req.sorter, req.sorter_name)
    add("SORTER-KISTE", req.sorter_chest_present, req.sorter_chest_name)
    add("WIRELESS-MODEM", req.wireless_modem)
    rows[#rows + 1] = { text = "MONITOR: " .. (req.monitor_is_term and "TERMINAL (Fallback)" or (req.monitor and "OK" or "FEHLT")),
      status = req.monitor and "OK" or "WARNING" }
  end

  local function diagnostics(mon, model)
    local w, h = header(mon, model, "REPROCESSING DIAGNOSTICS", "3/4", "network")
    local summary = model.summary or {}
    local alerts = model.local_alerts or {}
    local top = {
      { label = "HEALTH", value = tostring(model.status or "OK"), status = model.status or "OK", icon = "ok" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "ALARMS", value = tostring(#alerts), status = #alerts > 0 and "WARNING" or "OK", icon = "warning" },
    }

    if w >= 54 then
      local cw = math.floor((w - 5 - 3) / 4)
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, alerts)
    append_requirement_rows(rows, model.payload and model.payload.requirements)

    if w >= 58 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1

      mux.card(mon, 2, 10, left_w, math.max(9, h - 11), { title = "SYSTEM INFO", status = "LIMITED", icon = "network" })
      mux.data_row(mon, 4, 12, left_w - 4, { label = "REGISTRY", value = string.format("%d/%d/%d", summary.total or 0, summary.bound or 0, summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "network" })
      mux.data_row(mon, 4, 13, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" })
      mux.data_row(mon, 4, 14, left_w - 4, { label = "COMMAND", value = tostring(model.last_command or "none"), status = "text", icon = "config" })
      mux.data_row(mon, 4, 15, left_w - 4, { label = "DISCOVERY", value = devices.discovery_failed and "FAILED" or "OK", status = devices.discovery_failed and "WARNING" or "OK", icon = "network" })

      mux.card(mon, right_x, 10, right_w, math.max(9, h - 11), { title = "DIAGNOSTIC EVENTS", status = #alerts > 0 and "WARNING" or "OK", icon = "warning" })
      local y = 12
      for i = 1, math.min(#rows, math.max(0, h - y - 2)) do
        local r = rows[i]
        mux.data_row(mon, right_x + 2, y, right_w - 4, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    else
      section_arrow(mon, 2, 10, w - 3, "SYSTEM DIAGNOSTICS", "LIMITED", "network")
      local y = 12
      for i = 1, math.min(#rows, math.max(0, h - y - 1)) do
        local r = rows[i]
        mux.data_row(mon, 2, y, w - 3, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    end

    if utils then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
    return mux.footer_nav(mon, h, w, { center = "REPROC DIAGNOSTICS" })
  end

  local function diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    return support_ui_pages.handle_log_mode_touch(x, y, (h or 20) - 1, utils, 1)
  end

  return {
    render_overview = overview,
    render_details = details,
    render_diagnostics = diagnostics,
    handle_diagnostics_touch = diagnostics_touch,
  }
end

return M
