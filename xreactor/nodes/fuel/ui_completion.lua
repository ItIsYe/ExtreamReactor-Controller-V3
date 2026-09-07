-- nodes/fuel/ui_completion.lua
-- Fixed-SCADA completion layer for FUEL.
--
-- The old responsive Overview/Details renderers were intentionally removed.
-- This file now owns only view-state computation and attaches the fixed 82x40
-- SCADA presentation from nodes/fuel/scada_layout.lua.

local M = {}
local scada_layout = nil

local function affected(reactors, predicate)
  local out = {}
  for _, reactor in ipairs(reactors or {}) do
    if type(reactor) == "table" and predicate(reactor) then
      out[#out + 1] = tostring(reactor.label or reactor.reactor_id or "?")
    end
  end
  return out
end

function M.compute_view_state(model, devices, reserve, minimum)
  local payload = model and model.payload or {}
  local logistics = payload.logistics or {}
  local reactors = logistics.reactors or {}
  local bindings = payload.bindings or {}
  local valve = payload.valve_summary or {}

  if payload.protocol_mismatch or (devices and devices.proto_mismatch) then
    return { code = "ERROR", severity = "ERROR", title = "Protokollfehler", detail = "MASTER/FUEL Protokoll passt nicht", action = "Versionen pruefen" }
  end
  if #reactors == 0 then
    return { code = "CONFIG_REQUIRED", severity = "WARNING", title = "Konfiguration erforderlich", detail = "Keine Reaktoren konfiguriert", action = "ROUTER > REAKTOR EINLERNEN" }
  end
  if payload.routing_load_status and payload.routing_load_status.ok == false then
    return { code = "ROUTING_INVALID", severity = "WARNING", title = "Routing ungueltig", detail = tostring(payload.routing_load_status.message or payload.routing_load_status.code or "Fehler"), action = "fuel_routes.lua pruefen" }
  end
  if (tonumber(valve.offline) or 0) > 0 or (tonumber(valve.stale) or 0) > 0 then
    return {
      code = "VALVE_OFFLINE", severity = "WARNING", title = "Ventil-Verbindung nicht bereit",
      detail = string.format("offline=%d stale=%d", tonumber(valve.offline) or 0, tonumber(valve.stale) or 0),
      action = "VALVE-Node(s) und Funk pruefen",
    }
  end
  if (tonumber(bindings.storage) or 0) == 0 then
    return { code = "NO_STORAGE", severity = "WARNING", title = "Kein Reserve-Storage", detail = "storage_bus nicht gefunden", action = "Wired Modem/Storage pruefen" }
  end
  if payload.master_connected == false then
    return { code = "NO_FRESH_RT_DATA", severity = "WARNING", title = "MASTER/RT-Daten fehlen", detail = "MASTER nicht aktuell erreichbar", action = "MASTER- und RT-Verbindung pruefen" }
  end
  if logistics.enabled ~= true then
    return { code = "LOGISTICS_DISABLED", severity = "LIMITED", title = "Logistik deaktiviert", detail = "logistics.enabled = false", action = "Nur aktivieren, wenn Hardware bereit ist" }
  end
  if logistics.bridge == nil then
    return { code = "NO_ME_BRIDGE", severity = "WARNING", title = "ME Bridge fehlt", detail = "Keine betriebsbereite ME Bridge erkannt", action = "ME Bridge/Wired Modem pruefen" }
  end

  local blocked = affected(reactors, function(r) return r.operational_state == "BLOCKED" end)
  if #blocked > 0 then
    return { code = "LOGISTICS_BLOCKED", severity = "WARNING", title = "Lieferweg blockiert", detail = table.concat(blocked, ", "), action = "Inlet/Routing/VALVE pruefen" }
  end
  local missing = affected(reactors, function(r) return r.fuel_data_state == "MISSING" end)
  if #missing > 0 then
    return { code = "DATA_MISSING", severity = "WARNING", title = "Reaktordaten fehlen", detail = table.concat(missing, ", "), action = "reactor_id und RT-Status pruefen" }
  end
  local stale = affected(reactors, function(r) return r.fuel_data_state == "STALE" end)
  if #stale > 0 then
    return { code = "DATA_STALE", severity = "WARNING", title = "Reaktordaten veraltet", detail = table.concat(stale, ", "), action = "MASTER-/RT-Verbindung pruefen" }
  end

  reserve = tonumber(reserve ~= nil and reserve or payload.reserve)
  minimum = tonumber(minimum ~= nil and minimum or payload.minimum_reserve)
  if reserve and minimum and reserve < minimum then
    return { code = "RESERVE_LOW", severity = "WARNING", title = "Reserve niedrig", detail = tostring(reserve) .. " < " .. tostring(minimum), action = "Nachschub sicherstellen" }
  end

  if logistics.current_request then
    local request = logistics.current_request
    local detail = type(request) == "table" and tostring(request.label or request.reactor_id or request.state or "aktiv") or tostring(request)
    return { code = "DELIVERING", severity = "LIMITED", title = "Lieferung aktiv", detail = detail, action = nil }
  end
  return { code = "READY", severity = "OK", title = "Bereit", detail = "Alle konfigurierten Reaktoren sind betriebsbereit", action = nil }
end

function M.attach(instance, opts)
  if type(instance) ~= "table" then return instance end
  if instance._fuel_fixed_scada_attached then return instance end
  instance._fuel_fixed_scada_attached = true
  instance.compute_view_state = M.compute_view_state
  scada_layout = scada_layout or require("nodes.fuel.scada_layout")
  scada_layout.attach(instance, opts or {})
  return instance
end

return M
