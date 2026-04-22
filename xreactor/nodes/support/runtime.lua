local M = {}

function M.heartbeat_interval_ms(config)
  return math.max(1, tonumber(config.heartbeat_interval) or 2) * 1000
end

function M.make_presence(config, comms, ts_ms)
  return {
    ts = ts_ms,
    node_id = comms and comms.network and comms.network.id or config.node_id,
    role = config.role
  }
end

return M
