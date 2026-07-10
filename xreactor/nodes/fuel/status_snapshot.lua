-- nodes/fuel/status_snapshot.lua
--
-- Feature (2026-07-09): Modularisierungs-Rewrite. build_status_payload()
-- war bisher Teil von main.lua (zusammen mit Monitor-Setup, Kommando-
-- Verarbeitung, Service-Wiring in EINER Datei) — hier ausgelagert, analog
-- zu nodes/rt/status_snapshot.lua. Wird mit einer FRISCHEN ctx-Tabelle
-- pro Aufruf aufgerufen (main.lua baut ctx direkt vor jedem Aufruf neu
-- zusammen), damit veraenderliche Werte (reserve, master_seen_ts, ...)
-- immer aktuell sind, ohne dass dieses Modul main.lua's lokale Variablen
-- kennen muss.
--
-- Erwartete ctx-Felder:
--   config, devices, fuel_health, comms, registry, health, non_rt_payload,
--   master_alerts, master_seen_ts, reserve, storage (aktueller Wert oder nil),
--   read_fuel = function() -> number,
--   enforce_reserve = function(amount) -> number,
--   is_master_connected = function() -> bool,
--   get_router = function() -> logistics_router-Instanz (fuer get_summary()),

local M = {}

function M.build_status_payload(ctx)
  local health = ctx.health
  local non_rt_payload = ctx.non_rt_payload
  local devices = ctx.devices
  local config = ctx.config
  local fuel_health = ctx.fuel_health

  local amount = ctx.enforce_reserve(ctx.read_fuel())
  local has_storage = ctx.storage ~= nil
  local reasons = {}
  if not has_storage then reasons[health.reasons.NO_STORAGE] = true end
  if devices.discovery_failed or devices.registry_load_error then reasons[health.reasons.DISCOVERY_FAILED] = true end
  if devices.proto_mismatch then reasons[health.reasons.PROTO_MISMATCH] = true end
  local master_ok = ctx.is_master_connected()
  if not master_ok then reasons[health.reasons.COMMS_DOWN] = true end
  fuel_health.status = next(reasons) and health.status.DEGRADED or health.status.OK
  fuel_health.reasons = reasons
  fuel_health.last_seen_ts = os.epoch("utc")
  fuel_health.bindings = { storage = has_storage and 1 or 0 }
  fuel_health.capabilities = { storage = config.storage_bus ~= nil }

  local payload = non_rt_payload.build_base({
    ts = os.epoch("utc"), role = config.role, node_id = config.node_id,
    health = { status = fuel_health.status, reasons = health.reasons_list(fuel_health), last_seen_ts = fuel_health.last_seen_ts, bindings = fuel_health.bindings, capabilities = fuel_health.capabilities },
    discovery_failed = devices.discovery_failed, master_connected = master_ok,
    master_seen_s = ctx.master_seen_ts and math.max(0, math.floor((os.epoch("utc") - ctx.master_seen_ts) / 1000)) or nil,
    -- Fix (2026-07-09): CRITICAL, uralter Bug (existierte schon lange vor
    -- dieser Session, nicht Teil des Modularisierungs-Refactors). comms:
    -- queue_depth() existiert als Methode gar nicht -- comms_service hat
    -- nur get_diagnostics(), das ein queue_depth-FELD zurueckgibt. Dieser
    -- Aufruf warf bei JEDEM einzigen UI-Service-Tick einen Fehler ("attempt
    -- to call method 'queue_depth' (a nil value)"), der vom Service-Manager
    -- stillschweigend abgefangen wurde (siehe service_manager.lua pcall) --
    -- render_monitor() wurde dadurch NIE erreicht. Das erklaert vermutlich
    -- den kompletten "FUEL-Monitor bleibt schwarz"-Fall von Anfang an,
    -- unabhaengig von allen anderen in dieser Session gefixten Themen.
    queue = ctx.comms and ctx.comms:get_diagnostics().queue_depth or 0,
    peers = ctx.comms and ctx.comms.peer_state and ctx.comms.peer_state.peers or nil,
    alerts = ctx.master_alerts, protocol_mismatch = devices.proto_mismatch,
    last_command = devices.last_command, last_command_ts = devices.last_command_ts,
    registry = { summary = devices.registry_summary or ctx.registry:get_summary(), devices = ctx.registry:get_devices_by_kind(), diagnostics = ctx.registry:get_diagnostics() }
  })
  payload.reserve = amount
  payload.minimum_reserve = ctx.reserve
  payload.sources = { { id = devices.storage_name or "unknown", amount = amount } }
  payload.logistics = ctx.get_router():get_summary()
  payload.bindings = fuel_health.bindings
  payload.bindings_summary = health.summarize_bindings(fuel_health.bindings)
  return payload
end

return M
