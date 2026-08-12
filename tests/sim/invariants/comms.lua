-- tests/sim/invariants/comms.lua  Phase 7.2
-- Kommunikations-Invarianten: Kein Selbst-Echo, Channel-Registrierung.

local M = {}

-- Gesendete Nachrichten kommen nie beim Sender an
function M.no_self_echo(node_id)
  return function(world, tick)
    local received = world.received_from and world.received_from[node_id]
    if received then
      for _, src in ipairs(received) do
        if src == node_id then
          return false, string.format("tick=%d node %s received own message (self-echo)", tick, node_id)
        end
      end
    end
    return true
  end
end

-- Heartbeat kommt regelmäßig an (maximal interval Ticks Pause)
function M.heartbeat_received(node_id, max_gap_ticks)
  return function(world, tick)
    local last = world.last_heartbeat and world.last_heartbeat[node_id]
    if last and (tick - last) > max_gap_ticks then
      return false, string.format(
        "tick=%d node %s heartbeat gap %d > %d", tick, node_id, tick-last, max_gap_ticks)
    end
    return true
  end
end

-- Monad: immer true (Platzhalter bis echte Comms integriert)
function M.always_ok(label)
  return function(world, tick)
    return true
  end
end

return M
