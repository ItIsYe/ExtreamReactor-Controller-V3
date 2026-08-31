local M = {}
local mux = require("core.mockup_ui")

function M.new(opts)
  local ui = assert(opts.ui, "ui required")
  local support_ui_pages = assert(opts.support_ui_pages, "support_ui_pages required")
  local utils = opts.utils
  local devices = opts.devices or {}

  local function header(mon, model, title, page, icon, should_clear)
    local view_state = model.view_state
    local status = view_state and view_state.severity or model.status or "OK"
    local status_label = view_state and view_state.code or model.status or "OK"
    if should_clear == true then mux.clear(mon) end
    mux.header(mon, { title = title, node_id = model.node_id or "FU-?", page = page, status = status, icon = icon or "fuel" })
    local w = ({ mon.getSize() })[1]
    if w >= 66 then
      local cell = math.floor((w - 3) / 3)
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING", cell)
      mux.status_dot(mon, 2 + cell, 3, tostring(status_label), status, cell)
      mux.status_dot(mon, 2 + cell * 2, 3, "FUEL LINK", status, math.max(1, w - (2 + cell * 2)))
    elseif w >= 42 then
      local cell = math.floor((w - 3) / 2)
      mux.status_dot(mon, 2, 3, "MASTER " .. tostring(model.master_state or "?"), model.master_state == "OK" and "OK" or "WARNING", cell)
      mux.status_dot(mon, 2 + cell, 3, tostring(status_label), status, math.max(1, w - (2 + cell)))
    end
    return mon.getSize()
  end

  local function section_arrow(mon, x, y, w, title, status, icon)
    mux.section(mon, x, y, w, "> " .. title, status, icon)
  end

  local function diagnostics(mon, model, should_clear)
    local w, h = header(mon, model, "FUEL DIAGNOSTICS", "3/4", "network", should_clear)
    local summary = model.summary or {}
    local alerts = model.local_alerts or {}
    local top = {
      { label = "HEALTH", value = tostring(model.status or "OK"), status = model.status or "OK", icon = "ok" },
      { label = "MASTER", value = tostring(model.master_state or "?"), status = model.master_state == "OK" and "OK" or "WARNING", icon = "master" },
      { label = "MISSING", value = tostring(summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "warning" },
      { label = "ALARMS", value = tostring(#alerts), status = #alerts > 0 and "WARNING" or "OK", icon = "warning" },
    }

    if w >= 54 then
      local cw = math.max(5, math.floor((w - 8) / 4))
      for i, item in ipairs(top) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 5, cw, 4, item) end
    else
      mux.kpi_strip(mon, 2, 5, w - 3, top)
    end

    local rows = support_ui_pages.common_diagnostic_rows(model, devices.discovery_failed)
    support_ui_pages.append_local_alert_rows(rows, alerts)
    local uidiag = model.ui_diagnostics
    if model.view_state then
      rows[#rows + 1] = {
        text = "VIEW-STATE: " .. tostring(model.view_state.code) .. (model.view_state.action and (" -- " .. model.view_state.action) or ""),
        status = model.view_state.severity or "text",
      }
    end
    if uidiag then
      rows[#rows + 1] = {
        text = string.format("UI: REQ%d COM%d SKIP%d CLR%d TR%d ERR%d %dms PTR%d MOD%d",
          uidiag.frames_requested or 0, uidiag.frames_committed or 0, uidiag.frames_skipped or 0,
          uidiag.full_clears or 0, uidiag.transition_count or 0,
          uidiag.render_errors or uidiag.error_count or 0, uidiag.last_render_ms or 0,
          uidiag.pointer_events_received or 0, uidiag.model_builds or 0),
        status = "text",
      }
    end
    if uidiag and (uidiag.error_count or 0) > 0 then
      local le = uidiag.last_error or {}
      local age_txt = le.ts and support_ui_pages.format_age(le.ts, os.epoch("utc")) or "?"
      rows[#rows + 1] = {
        text = string.format("UI-FEHLER x%d (zuletzt: %s/%s vor %s)", uidiag.error_count, tostring(le.page or "?"), tostring(le.code or "?"), age_txt),
        status = "WARNING",
      }
    end

    if w >= 58 and h >= 18 then
      local left_w = math.floor((w - 5) / 2)
      local right_x = 3 + left_w
      local right_w = w - right_x - 1
      local card_h = math.max(5, h - 11)

      mux.card(mon, 2, 10, left_w, card_h, { title = "SYSTEM INFO", status = "LIMITED", icon = "network" })
      if card_h >= 3 then mux.data_row(mon, 4, 12, left_w - 4, { label = "REGISTRY", value = string.format("%d/%d/%d", summary.total or 0, summary.bound or 0, summary.missing or 0), status = (summary.missing or 0) > 0 and "WARNING" or "OK", icon = "network" }) end
      if card_h >= 4 then mux.data_row(mon, 4, 13, left_w - 4, { label = "LAST SCAN", value = tostring(model.last_scan or "-"), status = "LIMITED", icon = "network" }) end
      if card_h >= 5 then mux.data_row(mon, 4, 14, left_w - 4, { label = "COMMAND", value = tostring(model.last_command or "none"), status = "text", icon = "config" }) end
      if card_h >= 6 then mux.data_row(mon, 4, 15, left_w - 4, { label = "DISCOVERY", value = devices.discovery_failed and "FAILED" or "OK", status = devices.discovery_failed and "WARNING" or "OK", icon = "network" }) end

      mux.card(mon, right_x, 10, right_w, card_h, { title = "DIAGNOSTIC EVENTS", status = #alerts > 0 and "WARNING" or "OK", icon = "warning" })
      local y = 12
      local max_y = 10 + card_h - 1
      for i = 1, #rows do
        if y > max_y then break end
        local r = rows[i]
        mux.data_row(mon, right_x + 2, y, right_w - 4, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    else
      if h >= 11 then section_arrow(mon, 2, 10, w - 3, "SYSTEM DIAGNOSTICS", "LIMITED", "network") end
      local y = 12
      for i = 1, #rows do
        if y >= h - 1 then break end
        local r = rows[i]
        mux.data_row(mon, 2, y, w - 3, { label = tostring(r.text or ""), value = "", status = r.status or "text", icon = "network" })
        y = y + 1
      end
    end

    if utils and h >= 3 then support_ui_pages.render_log_mode_button(mon, utils, 1, h - 1, w - 2) end
    return mux.footer_nav(mon, h, w, { center = "FUEL DIAGNOSTICS" })
  end

  local function diagnostics_touch(mon, x, y)
    if not utils then return false end
    local _, h = ui.getSize(mon)
    return support_ui_pages.handle_log_mode_touch(x, y, (h or 20) - 1, utils, 1)
  end

  return {
    render_diagnostics = diagnostics,
    handle_diagnostics_touch = diagnostics_touch,
  }
end

return M
