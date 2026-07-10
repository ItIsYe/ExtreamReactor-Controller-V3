local M = {}
local mux = require("core.mockup_ui")

function M.draw_status_page(target, ui, colors, title, lines)
  local w, h = target.getSize()
  mux.clear(target)
  mux.header(target, { title = title or "STATUS", node_id = "LOCAL NODE", page = "STATUS", status = "OK", icon = "network" })
  mux.section(target, 2, 5, w - 3, "> SYSTEM STATUS", "LIMITED", "network")
  local y = 7
  for _, line in ipairs(lines or {}) do
    if y >= h then break end
    mux.data_row(target, 2, y, w - 3, { label = tostring(line), value = "", status = "text", icon = "network" })
    y = y + 1
  end
  if #(lines or {}) == 0 then
    mux.warning_box(target, 2, 7, w - 3, { "Keine Statusdaten", "Warte auf Telemetrie" }, "LIMITED")
  end
  mux.footer_nav(target, h, w, { center = "SYSTEM STATUS" })
end

function M.format_age(ts, now)
  if not ts then return "n/a" end
  return ("%ds"):format(math.max(0, math.floor((now - ts) / 1000)))
end

function M.render_alert_banner(target, ui, model)
  if model.local_alerts_critical and model.local_alerts_critical > 0 then
    local w = select(1, ui.getSize(target))
    if not w then return end
    local label = "CRIT " .. tostring(model.local_alerts_critical)
    ui.badge(target, w - (#label + 2), 1, label, "EMERGENCY")
  end
end

function M.append_local_alert_rows(rows, alerts)
  if type(alerts) ~= "table" or #alerts == 0 then return rows end
  table.insert(rows, { text = "> Local Alerts", status = "WARNING" })
  for _, alert in ipairs(alerts) do
    local sev = alert.severity and alert.severity:sub(1, 1) or "?"
    local title = alert.title or alert.message or alert.code or "alert"
    local status = alert.severity == "CRITICAL" and "EMERGENCY" or alert.severity == "WARN" and "WARNING" or "OK"
    table.insert(rows, { text = string.format("%s %s", sev, title), status = status })
  end
  return rows
end

-- Fix (2026-07-09): CRITICAL. build_common_model() lieferte bisher KEIN
-- 'snapshot'-Feld -- core/ui_router.lua's Render-Diff-Pruefung
-- (build_snapshot() dort) faellt in diesem Fall auf eine Serialisierung
-- des KOMPLETTEN Models zurueck, inklusive roher Epoch-Zeitstempel
-- (payload.ts, payload.health.last_seen_ts, ...), die sich bei JEDEM
-- Aufruf aendern -- die Diff-Pruefung erkannte dadurch faelschlich IMMER
-- eine Aenderung und loeste ein hartes Voll-Neu-Rendern aus, selbst wenn
-- sich inhaltlich nichts geaendert hatte. RT (und andere Nodes, die ihr
-- eigenes model.snapshot bauen) waren davon nicht betroffen. Hier: ein
-- bereinigter Snapshot ohne die bekannten Rausch-Zeitstempel, aber mit
-- allem inhaltlich Relevanten (damit z.B. ein geaenderter Fuellstand
-- weiterhin korrekt ein Redraw ausloest).
local function scrub_timestamps(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    if k == "ts" or k == "last_seen_ts" or k == "timestamp" then
      -- bewusst weggelassen -- reines Rauschen fuer den Vergleich
    else
      out[k] = scrub_timestamps(v)
    end
  end
  return out
end

function M.build_common_model(args)
  local payload = args.payload
  local peer = args.master_peer
  local now = args.now
  local comms_diag = args.comms_diag or {}
  local metrics = comms_diag.metrics or {}
  local model = {
    payload = payload,
    status = payload.health and payload.health.status or "OK",
    summary = args.summary,
    comms = comms_diag,
    metrics = metrics,
    master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN",
    master_age = peer and peer.age and string.format("%ds", math.floor(peer.age)) or "n/a",
    last_scan = M.format_age(args.last_scan_ts, now),
    last_command = args.last_command,
    last_command_ts = args.last_command_ts and M.format_age(args.last_command_ts, now) or "n/a",
    local_alerts = args.local_alerts or {},
    local_alerts_critical = args.local_alerts_critical or 0,
    node_id = args.node_id
  }
  model.snapshot = {
    page_data = scrub_timestamps(payload),
    status = model.status, summary = model.summary, master_state = model.master_state,
    local_alerts = model.local_alerts, local_alerts_critical = model.local_alerts_critical,
  }
  return model
end

function M.render_log_mode_button(target, utils_ref, x, y, w)
  local CC_BLACK = 32768
  local CC_WHITE = 1
  local CC_GREEN = 32
  local CC_GRAY  = 256
  if not utils_ref then return end
  if type(target.setBackgroundColor) ~= "function" then return end
  local mode = utils_ref.get_log_mode and utils_ref.get_log_mode() or "all"
  local modes = { "all", "disk", "remote", "terminal", "none" }
  local labels = { all = "All ", disk = "Disk", remote = "Rmt ", terminal = "Term", none = "Off " }
  local btn_w = 4
  local cx = (x or 2)
  target.setBackgroundColor(CC_BLACK)
  target.setTextColor(CC_GRAY)
  target.setCursorPos(cx, y or 2)
  target.write("Log:")
  cx = cx + 4
  for _, m in ipairs(modes) do
    target.setCursorPos(cx, y or 2)
    target.setBackgroundColor(mode == m and CC_GREEN or CC_GRAY)
    target.setTextColor(mode == m and CC_BLACK or CC_WHITE)
    target.write(labels[m] or m)
    target.setBackgroundColor(CC_BLACK)
    cx = cx + btn_w
  end
end

function M.handle_log_mode_touch(tx, ty, btn_y, utils_ref, x)
  if not utils_ref or ty ~= (btn_y or 0) then return false end
  local modes = { "all", "disk", "remote", "terminal", "none" }
  local cx = (x or 2) + 4
  for _, m in ipairs(modes) do
    if tx >= cx and tx < cx + 4 then
      if utils_ref.set_log_mode then utils_ref.set_log_mode(m) end
      return true
    end
    cx = cx + 4
  end
  return false
end

function M.common_diagnostic_rows(model, discovery_failed)
  return {
    { text = ("Health: %s"):format(model.status), status = model.status },
    { text = ("Discovery: %s"):format(discovery_failed and "FAILED" or "OK"), status = discovery_failed and "WARNING" or "OK" },
    { text = ("Registry total:%d bound:%d missing:%d"):format(model.summary.total or 0, model.summary.bound or 0, model.summary.missing or 0), status = (model.summary.missing or 0) > 0 and "WARNING" or "OK" },
    { text = ("Master link: %s age:%s"):format(model.master_state, model.master_age), status = model.master_state == "OK" and "OK" or "WARNING" },
    { text = ("Comms q:%d inflight:%d retries:%d"):format(model.comms.queue_depth or 0, model.comms.inflight_count or 0, model.metrics.retries or 0), status = (model.metrics.retries or 0) > 0 and "LIMITED" or "OK" },
    { text = ("Comms dropped:%d dedupe:%d timeouts:%d"):format(model.metrics.dropped or 0, model.metrics.dedupe_hits or 0, model.metrics.timeouts or 0), status = ((model.metrics.dropped or 0) + (model.metrics.timeouts or 0)) > 0 and "WARNING" or "OK" },
    { text = ("Last cmd: %s (%s)"):format(model.last_command or "none", model.last_command_ts), status = "text" }
  }
end

return M
