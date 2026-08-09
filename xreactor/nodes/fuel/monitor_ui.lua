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
local router_ui_responsive = require("nodes.fuel.router_ui_responsive")

local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

local monitor_router = nil
local current_mon = nil
local render_buffer = { parent = nil, name = nil, width = nil, height = nil, target = nil }

local function reset_render_buffer()
  render_buffer = { parent = nil, name = nil, width = nil, height = nil, target = nil }
end

local function get_render_target(mon, monitor_name)
  if not mon or type(mon.getSize) ~= "function" then return mon end
  if type(window) ~= "table" or type(window.create) ~= "function" then return mon end

  local ok_size, w, h = pcall(mon.getSize)
  if not ok_size or type(w) ~= "number" or type(h) ~= "number" or w < 1 or h < 1 then
    return mon
  end

  if render_buffer.target
      and render_buffer.parent == mon
      and render_buffer.name == monitor_name
      and render_buffer.width == w
      and render_buffer.height == h
      and type(render_buffer.target.setVisible) == "function" then
    return render_buffer.target
  end

  local ok_window, target = pcall(window.create, mon, 1, 1, w, h, false)
  if not ok_window or not target or type(target.setVisible) ~= "function" then
    reset_render_buffer()
    return mon
  end

  render_buffer = {
    parent = mon,
    name = monitor_name,
    width = w,
    height = h,
    target = target,
  }
  return target
end

local function render_frame(router, target, physical_mon, model)
  local buffered = target ~= physical_mon and type(target.setVisible) == "function"
  if buffered then
    -- A CC:Tweaked window created with visible=false is a real off-screen
    -- buffer: hide it before every frame, render the complete frame, then
    -- publish it in one step. Never call setVisible on the physical monitor.
    pcall(target.setVisible, false)
  end
  router:render(target, model)
  if buffered then
    pcall(target.setVisible, true)
  end
end

-- Feature (2026-07-12): REST-P1.4. Zaehler, die AUSSERHALB des Routers
-- entstehen -- werden in M.get_diagnostics() mit dem Router-eigenen
-- Zustand zusammengefuehrt.
local ui_diag_extra = { pointer_events_received = 0, page_handler_calls = 0, model_builds = 0 }

-- Feature (2026-07-12): REST-P1.3. Bildet den priorisierten view_state
-- (siehe ui_pages.lua M.compute_view_state()) auf einen Ampel-Farbcode
-- ab. Die EMERGENCY-Sonderpruefung fuer einen kritisch niedrigen
-- PRO-REAKTOR-Fuellstand bleibt als zusaetzliche Eskalation erhalten --
-- das ist ein eigenstaendiges Signal, das die Prioritaetsliste des
-- Dokuments nicht abdeckt (dort geht es um FUEL-Node-Zustaende, nicht um
-- einzelne Reaktor-Fuellstaende).
local VIEW_STATE_TO_AMPEL = {
  ERROR = "EMERGENCY", NO_CONFIG = "WARNING", ROUTING_INVALID = "WARNING",
  VALVE_OFFLINE = "WARNING", NO_STORAGE = "WARNING", NO_FRESH_RT_DATA = "WARNING",
  LOGISTICS_DISABLED = "muted", RESERVE_LOW = "WARNING", DELIVERING = "LIMITED",
  READY = "OK", LOADING = "LIMITED",
}
local function fuel_ampel_status(view_state, logistics)
  for _, r in ipairs((logistics or {}).reactors or {}) do
    if type(r.fuel_pct) == "number" and r.fuel_pct < 10 then return "EMERGENCY" end
  end
  return VIEW_STATE_TO_AMPEL[view_state.code] or "WARNING"
end

-- ctx: { build_status_payload, master_peer_state, devices, fuel_ui }
function M.render_ampel(ctx)
  if not ampel_instance then return end
  pcall(function()
    local payload = ctx.build_status_payload()
    local view_state = ctx.fuel_ui.compute_view_state({ payload = payload }, ctx.devices, payload.reserve, payload.minimum_reserve)
    ampel_instance.render(ctx.devices.monitor_name, fuel_ampel_status(view_state, payload.logistics))
  end)
end

-- Feature (2026-07-11): UI-P0.4 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_
-- FIX_2026-07-12.md). Model-Aufbau von der eigentlichen Zeichnung
-- getrennt -- M.build_model() wird GENAU EINMAL pro UI-Zyklus von
-- services/ui_service.lua aufgerufen (ueber build_model=...), das
-- Ergebnis wird DIREKT an M.render_monitor() durchgereicht. Vorher baute
-- render_monitor() sein eigenes, unabhaengiges Model -- moeglicherweise
-- mit anderen Werten als das, was fuer den Snapshot-Vergleich benutzt
-- wurde (Zeitstempel/Registry-/Comms-Auswertung konnten zwischen den
-- beiden Aufrufen leicht auseinanderlaufen).
--
-- ctx: { devices, build_status_payload, comms, master_peer_state, registry,
--        config, master_alerts, support_ui_pages }
function M.build_model(ctx)
  ui_diag_extra.model_builds = ui_diag_extra.model_builds + 1
  local devices = ctx.devices
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
  -- Feature (2026-07-12): REST-P1.1. Vorher hat build_model() den error_
  -- count/last_error-Zustand des ui_routers nirgends uebernommen -- die
  -- FUEL-Diagnostics-Seite konnte diese Werte dadurch gar nicht anzeigen,
  -- obwohl der Router sie intern schon korrekt verfolgt hat. error_count
  -- zusaetzlich in den Vergleichs-Snapshot aufgenommen (einfache Zahl,
  -- billig zu vergleichen), damit ein NEUER Fehler sofort sichtbar wird,
  -- falls die Diagnostics-Seite gerade angezeigt wird -- last_error.ts
  -- wird durch das bestehende Zeitstempel-Muster in scrub_timestamps()
  -- ohnehin schon aus dem Snapshot herausgefiltert.
  model.ui_diagnostics = M.get_diagnostics()
  -- Feature (2026-07-12): REST-P1.3. view_state EINMAL zentral berechnet
  -- (statt nur als Nebeneffekt eines overview()-Aufrufs, der bei anderen
  -- aktiven Seiten gar nicht laeuft) -- Header/Banner/Ampel/Diagnostics
  -- lesen jetzt alle DENSELBEN bereits fertigen Wert.
  model.view_state = ctx.fuel_ui.compute_view_state(model, devices, payload.reserve, payload.minimum_reserve)
  if type(model.snapshot) == "table" then
    model.snapshot.ui_error_count = model.ui_diagnostics.error_count
    model.snapshot.view_state_code = model.view_state.code
  end
  return model
end

-- ctx: { devices, ui_router, fuel_ui, get_router_ui, ui, colors, keys }
-- model: das bereits fertig gebaute Model (siehe M.build_model() oben)
function M.render_monitor(ctx, model)
  local devices = ctx.devices
  if not devices.monitor then return end
  local mon = devices.monitor
  current_mon = mon
  local render_target = get_render_target(mon, devices.monitor_name)
  if not monitor_router then
    local fuel_ui = ctx.fuel_ui
    local function responsive_router_ui()
      return router_ui_responsive.attach(ctx.get_router_ui())
    end
    monitor_router = ctx.ui_router.new({
      error_title = "FUEL UI ERROR",
      on_render_error = ctx.on_render_error,
      pages = {
        { name = "Overview", render = ctx.fuel_ui.render_overview },
        { name = "Details", render = ctx.fuel_ui.render_details },
        { name = "Diagnostics", render = ctx.fuel_ui.render_diagnostics,
          handle_touch = function(x, y) return fuel_ui.handle_diagnostics_touch(current_mon, x, y) end },
        { name = "Router", render = function(target, model, should_clear) return responsive_router_ui():render(target, ctx.ui, ctx.colors, should_clear) end,
          handle_touch = function(x, y) return responsive_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [ctx.keys.left] = true, [ctx.keys.pageUp] = true },
      key_next = { [ctx.keys.right] = true, [ctx.keys.pageDown] = true }
    })
  end
  render_frame(monitor_router, render_target, mon, model)
end

-- Fix (2026-07-09): CRITICAL. Beim Modularisierungs-Refactor wurde hier
-- nur der seitenspezifische Touch-Handler (page.handle_touch, z.B. fuer
-- die Router-Seite) aufgerufen -- der eigentliche Aufruf, der die
-- WEITER/ZURUECK-Footer-Navigation behandelt (monitor_router:handle_
-- input(event)), fehlte komplett. Jetzt wieder wie im Original: main.lua
-- muss M.handle_input(event) mit dem VOLLEN Event aufrufen (nicht nur
-- x/y), das leitet zuerst an den Router selbst weiter (Seiten-Navigation)
-- und DANACH an die seitenspezifische Touch-Behandlung.
--
-- Fix (2026-07-11): CRITICAL (UI-P0.2, siehe docs/CODING_AI_FUEL_UI_
-- PRIORITY_FIX_2026-07-12.md). Der Rueckgabewert von monitor_router:
-- handle_input() wurde bisher IGNORIERT -- ein Footer-Touch, der die
-- Seite wechselte, wurde DANACH trotzdem noch an den seitenspezifischen
-- Handler der NEU ausgewaehlten Seite weitergereicht. Lag an denselben
-- Koordinaten zufaellig ein Button der neuen Seite, wurde er zusaetzlich
-- ausgeloest (z.B. Seitenwechsel + gleichzeitiges Setzen/Loeschen einer
-- Routerauswahl). Jetzt: sobald eine Ebene das Event konsumiert (true
-- zurueckgibt), stoppt die Weitergabe sofort -- exakt wie im Dokument
-- vorgeschrieben. M.handle_input() selbst gibt jetzt ebenfalls true/false
-- zurueck (Event konsumiert oder nicht), damit aufrufende Ebenen (z.B.
-- ein kuenftiger zentraler Dispatcher) das respektieren koennen.
function M.handle_input(event)
  -- Feature (2026-07-12): REST-P1.4. Genau EIN Inkrement pro physischem
  -- Touch-/Tasten-Event -- NICHT bei jedem Aufruf, da ui_service.lua
  -- handle_input() fuer JEDES Event (auch passive modem_message)
  -- aufruft. Nur echte Zeiger-/Tasten-Ereignisse zaehlen.
  local kind = event and event[1]
  if kind == "monitor_touch" or kind == "mouse_click" or kind == "key" or kind == "char" then
    ui_diag_extra.pointer_events_received = ui_diag_extra.pointer_events_received + 1
  end
  if monitor_router and monitor_router:handle_input(event) then
    return true
  end
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    local x, y = event and event[3], event and event[4]
    ui_diag_extra.page_handler_calls = ui_diag_extra.page_handler_calls + 1
    return page.handle_touch(x, y) == true
  end
  return false
end

function M.handle_touch(x, y)
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then return page.handle_touch(x, y) end
end

function M.current_page_index()
  return monitor_router and monitor_router.index or 1
end

-- Feature (2026-07-12): REST-P1.1. Reicht den error_count/last_error-
-- Zustand des Routers weiter -- Grundlage dafuer, dass build_model()
-- diese Werte in das Model uebernehmen kann, damit die Diagnostics-Seite
-- sie tatsaechlich anzeigt (vorher blieben sie nur intern im Router).
function M.get_diagnostics()
  local base = monitor_router and monitor_router.get_diagnostics and monitor_router:get_diagnostics() or { error_count = 0, last_error = nil }
  base.pointer_events_received = ui_diag_extra.pointer_events_received
  base.page_handler_calls = ui_diag_extra.page_handler_calls
  base.model_builds = ui_diag_extra.model_builds
  return base
end

return M
