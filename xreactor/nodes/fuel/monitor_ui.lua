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
local current_mon = nil

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
  local devices = ctx.devices
  local payload = ctx.build_status_payload()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local peer = ctx.master_peer_state()
  local summary = payload.registry and payload.registry.summary or ctx.registry:get_summary()
  local now = os.epoch("utc")
  local current_node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[current_node_id] or nil
  return ctx.support_ui_pages.build_common_model({
    payload = payload, summary = summary, comms_diag = comms_diag, master_peer = peer, now = now,
    last_scan_ts = devices.last_scan_ts, last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    local_alerts = alert_payload and alert_payload.top or {}, local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = current_node_id
  })
end

-- ctx: { devices, ui_router, fuel_ui, get_router_ui, ui, colors, keys }
-- model: das bereits fertig gebaute Model (siehe M.build_model() oben)
function M.render_monitor(ctx, model)
  local devices = ctx.devices
  if not devices.monitor then return end
  local mon = devices.monitor
  -- Fix (2026-07-10): CRITICAL. Die Seiten wurden bisher mit Closures wie
  -- "function(target) return fuel_ui.render_overview(target, model) end"
  -- gebaut -- das faengt "model" (und bei Diagnostics auch "mon") beim
  -- ALLERERSTEN Aufruf ein und friert es fuer immer ein, da monitor_router
  -- nur EINMAL (lazy init) gebaut wird, waehrend render_monitor() bei
  -- jedem Tick ein NEUES model erzeugt. Jede Seite zeigte dadurch dauerhaft
  -- den Stand vom allerersten Render, egal was sich seitdem geaendert hat
  -- -- exakt das gemeldete "immer hartes Rendern"-Symptom (der Diff-Check
  -- in ui_router.lua vergleicht zwar korrekt das FRISCHE model, aber die
  -- tatsaechlich gezeichnete Seite nutzte trotzdem immer die eingefrorene
  -- Kopie), und vermutlich auch Ursache dafuer, dass manche Seiten (mit
  -- noch unvollstaendigen Daten beim allerersten Aufruf) dauerhaft leer/
  -- fehlerhaft blieben. Jetzt wie bei RT: render_overview/render_details/
  -- render_diagnostics werden DIREKT als page.render zugewiesen -- ihre
  -- Signatur ist bereits exakt (mon, model), passt 1:1 zu dem, was
  -- router:render(mon, model) tatsaechlich an page.render() durchreicht.
  current_mon = mon
  if not monitor_router then
    local fuel_ui = ctx.fuel_ui
    monitor_router = ctx.ui_router.new({
      pages = {
        { name = "Overview", render = ctx.fuel_ui.render_overview },
        { name = "Details", render = ctx.fuel_ui.render_details },
        { name = "Diagnostics", render = ctx.fuel_ui.render_diagnostics,
          handle_touch = function(x, y) return fuel_ui.handle_diagnostics_touch(current_mon, x, y) end },
        { name = "Router", render = function(target) ctx.get_router_ui():render(target, ctx.ui, ctx.colors) end,
          handle_touch = function(x, y) return ctx.get_router_ui():handle_touch(x, y) end }
      },
      key_prev = { [ctx.keys.left] = true, [ctx.keys.pageUp] = true },
      key_next = { [ctx.keys.right] = true, [ctx.keys.pageDown] = true }
    })
  end
  monitor_router:render(mon, model)
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
  if monitor_router and monitor_router:handle_input(event) then
    return true
  end
  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    local x, y = event and event[3], event and event[4]
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

return M
