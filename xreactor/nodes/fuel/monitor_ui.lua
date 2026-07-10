-- nodes/fuel/monitor_ui.lua
--
-- Feature (2026-07-09): Modularisierungs-Rewrite. Buendelt alles rund um
-- den Haupt-Monitor und die Ampel an einer Stelle, analog zu nodes/rt/
-- monitor_ui.lua. Das Modul haelt seinen eigenen Lebenszyklus-State
-- (monitor_router, ampel_instance) -- main.lua ruft nur M.render_monitor(ctx)
-- / M.render_ampel(ctx) mit einer frischen ctx-Tabelle pro Aufruf auf.
--
-- Fix (2026-07-09): render_ampel() war urspruenglich hinter "if not
-- devices.monitor then return end" versteckt (in render_monitor()) --
-- lief also NIE, wenn (noch) kein Hauptmonitor gefunden wurde, obwohl die
-- Ampel-Erkennung selbst komplett unabhaengig ist. Hier von Anfang an als
-- eigenstaendige Funktion aufgebaut.

local M = {}

local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

local monitor_router = nil

-- Fix (2026-07-09): Ampel-Status fuer FUEL ableiten, analog zu rt_status()
-- in nodes/rt/monitor_ui.lua. Master-Verbindung > aktive Fehler > kritisch
-- niedriger Reaktor-Fuellstand > gerade aktive Lieferung > normal.
local function fuel_ampel_status(model)
  if model.master_state and model.master_state ~= "OK" then return "WARNING" end
  local logistics = (model.payload and model.payload.logistics) or {}
  if logistics.enabled == false then return "muted" end
  if tonumber(logistics.total_errors or 0) > 0 then return "WARNING" end
  for _, r in ipairs(logistics.reactors or {}) do
    if type(r.fuel_pct) == "number" and r.fuel_pct < 10 then return "EMERGENCY" end
  end
  if logistics.current_request then return "LIMITED" end
  return "OK"
end

-- ctx: { build_status_payload, master_peer_state, devices }
function M.render_ampel(ctx)
  if not ampel_instance then return end
  pcall(function()
    local payload = ctx.build_status_payload()
    local peer = ctx.master_peer_state()
    local model = {
      master_state = peer and (peer.down and "DOWN" or "OK") or "UNKNOWN",
      payload = payload,
    }
    ampel_instance.render(ctx.devices.monitor_name, fuel_ampel_status(model))
  end)
end

-- ctx: { devices, build_status_payload, comms, master_peer_state, registry,
--        config, master_alerts, support_ui_pages, ui_router, fuel_ui,
--        get_router_ui, ui, colors, keys }
function M.render_monitor(ctx)
  local devices = ctx.devices
  if not devices.monitor then return end
  local mon = devices.monitor
  local payload = ctx.build_status_payload()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local peer = ctx.master_peer_state()
  local summary = payload.registry and payload.registry.summary or ctx.registry:get_summary()
  local now = os.epoch("utc")
  local current_node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[current_node_id] or nil
  local model = ctx.support_ui_pages.build_common_model({
    payload = payload, summary = summary, comms_diag = comms_diag, master_peer = peer, now = now,
    last_scan_ts = devices.last_scan_ts, last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = current_node_id
  })
  if not monitor_router then
    local fuel_ui = ctx.fuel_ui
    monitor_router = ctx.ui_router.new({
      pages = {
        { name = "Overview", render = function(target) return fuel_ui.render_overview(target, model) end },
        { name = "Details", render = function(target) return fuel_ui.render_details(target, model) end },
        { name = "Diagnostics", render = function(target) return fuel_ui.render_diagnostics(target, model) end,
          handle_touch = function(x, y) return fuel_ui.handle_diagnostics_touch(mon, x, y) end },
        { name = "Router", render = function(target) ctx.get_router_ui():render(target, ctx.ui, ctx.colors) end,
          handle_touch = function(x, y) return ctx.get_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [ctx.keys.left] = true, [ctx.keys.pageUp] = true },
      key_next = { [ctx.keys.right] = true, [ctx.keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
end

function M.handle_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then return page.handle_touch(x, y) end
end

function M.current_page_index()
  return monitor_router and monitor_router.index or 1
end

return M
