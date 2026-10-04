local M = {}

-- Der FRISCHESTE MASTER-Peer, nicht ein beliebiger.
--
-- Vorher lief hier ein pairs()-Durchlauf mit return beim ersten Treffer.
-- Die Reihenfolge von pairs() ist in Lua nicht festgelegt, und die
-- Peer-Tabelle kann mehrere MASTER-Eintraege enthalten: einen abgemeldeten
-- unter einer alten Knoten-Kennung und den laufenden. Welchen der Durchlauf
-- erwischte, war Zufall -- und erwischte er den alten, meldete der
-- Health-Check "MASTER DOWN", waehrend der Regler sauber im Zustand MASTER
-- lief. Genau diese Art zweiter Wahrheit soll der Umbau beseitigen, also
-- wird hier eindeutig entschieden: der juengste Eintrag gewinnt.
function M.master_peer_state(ctx)
  local peers = ctx.comms and ctx.comms:get_peers() or {}
  local best, best_age = nil, nil
  for _, data in pairs(peers) do
    if data.role == ctx.constants.roles.MASTER then
      local age = tonumber(data.age)
      if best == nil then
        best, best_age = data, age
      elseif age ~= nil and (best_age == nil or age < best_age) then
        best, best_age = data, age
      end
    end
  end
  return best
end

-- Schwelle fuer den Rueckfallweg. Sie MUSS dieselbe sein, mit der
-- core/comms.lua seine Peer-Tabelle fuehrt und mit der
-- nodes/rt/rt2_master_link.lua den Betriebszustand entscheidet
-- (config.comms.peer_timeout_s, Default 20 s).
--
-- Vorher stand hier ctx.hb * 5, bei einem Heartbeat von 2 s also 10 s --
-- eine DRITTE Schwelle fuer dieselbe Tatsache, neben den 20 s der
-- Peer-Tabelle und den 20 s der Zustandsmaschine. Der Knoten konnte damit
-- "MASTER DOWN" anzeigen, waehrend er im Zustand MASTER regelte: genau die
-- Meldung, wegen der peer_timeout_s ueberhaupt auf 20 s angehoben wurde.
M.DEFAULT_PEER_TIMEOUT_S = 20.0

function M.is_master_connected(ctx)
  local peer = M.master_peer_state(ctx)
  if peer then
    return not peer.down, peer.age
  end
  -- Kein Peer-Eintrag: der Rueckfallweg auf den eigenen Zeitstempel.
  --
  -- ctx.master_seen ist nil, solange NIE eine MASTER-Nachricht ankam, und
  -- das muss "nicht verbunden" heissen. main.lua hat hier bisher
  -- (master_seen_ts or os.epoch("utc")) uebergeben -- ein nie gesehener
  -- MASTER kam damit mit einem Alter von 0 ms an und galt als verbunden.
  -- Eine Node, die noch keinen MASTER gehoert hat, meldete also eine
  -- gesunde MASTER-Verbindung.
  local seen = tonumber(ctx.master_seen)
  if seen then
    local timeout_s = tonumber(ctx.peer_timeout_s) or M.DEFAULT_PEER_TIMEOUT_S
    local age = (os.epoch("utc") - seen) / 1000
    -- Wie ueberall: ein Zeitstempel aus der Zukunft (Uhr-Ruecksprung) ist
    -- wertlos, nicht "ganz frisch".
    if age < 0 then return false, age end
    return age <= timeout_s, age
  end
  return false, nil
end

function M.build_health_payload(ctx)
  local reasons = {}
  local degrade_reasons = {}
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary()
  local binding_policy = ctx.binding.build_policy(ctx.configured_reactors, ctx.configured_turbines)
  local bound_reactors = summary.kinds.reactor and summary.kinds.reactor.bound or 0
  local bound_turbines = summary.kinds.turbine and summary.kinds.turbine.bound or 0
  if bound_reactors == 0 then
    reasons[ctx.health.reasons.NO_REACTOR] = true
    ctx.warn_once("reactors_missing_health", ctx.binding.missing_devices_message("reactor", binding_policy))
  end
  if bound_turbines == 0 then
    reasons[ctx.health.reasons.NO_TURBINE] = true
    ctx.warn_once("turbines_missing_health", ctx.binding.missing_devices_message("turbine", binding_policy))
  end
  if ctx.devices.discovery_failed or ctx.devices.registry_load_error then
    reasons[ctx.health.reasons.DISCOVERY_FAILED] = true
    degrade_reasons[ctx.health.reasons.DISCOVERY_FAILED] = true
  end
  if ctx.devices.proto_mismatch then
    reasons[ctx.health.reasons.PROTO_MISMATCH] = true
    degrade_reasons[ctx.health.reasons.PROTO_MISMATCH] = true
  end
  if ctx.startup_watchdog_tripped then
    reasons[ctx.health.reasons.CONTROL_DEGRADED] = true
    degrade_reasons[ctx.health.reasons.CONTROL_DEGRADED] = true
  end
  -- Ein verlorenes Timer-Ereignis hat die Node frueher bis zum Neustart
  -- stillgelegt (nodes/support/runtime.lua's wait_cycle). Heute laeuft sie
  -- weiter -- der Grund bleibt bis zum Neustart stehen, damit sichtbar
  -- bleibt, dass es passiert ist; MASTER protokolliert jede Aenderung der
  -- Gruende. Bewusst KEIN Herabstufen: die Node regelt ja.
  if (tonumber(ctx.timers_lost) or 0) > 0 then
    reasons[ctx.health.reasons.TIMER_LOST or "TIMER_LOST"] = true
  end
  local connected = M.is_master_connected(ctx)
  if not connected then
    reasons[ctx.health.reasons.COMMS_DOWN] = true
    degrade_reasons[ctx.health.reasons.COMMS_DOWN] = true
  end
  local status = next(degrade_reasons) and ctx.health.status.DEGRADED or ctx.health.status.OK
  ctx.rt_health.status = status
  ctx.rt_health.reasons = reasons
  ctx.rt_health.last_seen_ts = os.epoch("utc")
  ctx.rt_health.bindings = {
    reactors = bound_reactors,
    turbines = bound_turbines
  }
  ctx.rt_health.capabilities = { reactors = ctx.configured_caps.reactors, turbines = ctx.configured_caps.turbines }
  return {
    status = ctx.rt_health.status,
    reasons = ctx.health.reasons_list(ctx.rt_health),
    last_seen_ts = ctx.rt_health.last_seen_ts,
    bindings = ctx.rt_health.bindings,
    capabilities = ctx.rt_health.capabilities
  }
end

return M
