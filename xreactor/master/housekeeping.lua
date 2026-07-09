local M = {}

function M.handle_command_timeouts(opts)
  local constants = opts.constants
  local utils = opts.utils
  local comms = opts.comms
  local nodes = opts.nodes
  local log = opts.log
  local timeouts = comms:consume_timeouts() or {}
  for _, entry in ipairs(timeouts) do
    local msg = entry.message or {}
    if msg.type == constants.message_types.COMMAND then
      local node_id = utils.normalize_node_id(msg.dst or (msg.payload and msg.payload.target))
      if node_id ~= "UNKNOWN" then
        nodes[node_id] = nodes[node_id] or { id = node_id, role = "UNKNOWN", status = constants.status_levels.OFFLINE }
        local command = msg.payload and msg.payload.command or {}
        nodes[node_id].last_command_result = {
          ok = false,
          error = "ack timeout",
          reason_code = "ACK_TIMEOUT",
          ack_for = msg.message_id,
          at = os.epoch("utc"),
          command_target = command.target,
          command_value = command.value
        }
        nodes[node_id].last_command_error = "ack timeout"
        log(("Command timeout for %s (%s)"):format(tostring(node_id), tostring(command.target or "unknown")), "WARN")
      end
    end
  end
end

function M.build_master_alert_payload(alert_service, config)
  local by_node = {}
  local limit = config.alert_node_top_n or 3
  local active = alert_service and alert_service:get_active() or {}
  for _, alert in ipairs(active) do
    local node_id = alert.source and alert.source.node_id
    if node_id then
      local entry = by_node[node_id] or { critical = 0, top = {} }
      if alert.severity == "CRITICAL" then entry.critical = entry.critical + 1 end
      if #entry.top < limit then
        table.insert(entry.top, { severity = alert.severity, title = alert.title, message = alert.message, code = alert.code })
      end
      by_node[node_id] = entry
    end
  end
  return { alerts = { ts = os.epoch("utc"), by_node = by_node } }
end

-- Fix P6: housekeeping_tick war ein unlesbares inline-Lambda in runtime_loop.lua.
-- Jetzt saubere Funktion hier, runtime_loop ruft housekeeping.tick(runtime) auf.
function M.tick(runtime)
  M.handle_command_timeouts({
    constants = runtime.libs.constants,
    utils = runtime.libs.utils,
    comms = runtime.refs.comms,
    nodes = runtime.state.nodes,
    log = runtime.log
  })
  if runtime.refs.sequencer then
    runtime.refs.sequencer:tick(runtime.state.nodes)
  end
  -- M1: flush über den kanonischen runtime-Wrapper, nicht direkt auf Coalescer
  if runtime.flush_rt_sync_queue then
    runtime.flush_rt_sync_queue()
  end
  local rt_ops = runtime.libs.rt_ops
  if rt_ops then
    rt_ops.check_timeouts(runtime)
  end
  local profile_ops = runtime.libs.profile_ops
  if profile_ops then
    profile_ops.sample_trends(runtime)
  end
  -- Feature (2026-07-08): Reaktor-Fuellstand periodisch an FUEL-Nodes
  -- weiterleiten (siehe master/fuel_relay.lua).
  local fuel_relay = runtime.libs.fuel_relay
  if fuel_relay then
    fuel_relay.tick(runtime)
  end
end

return M
