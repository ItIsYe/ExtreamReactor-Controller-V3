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

return M
