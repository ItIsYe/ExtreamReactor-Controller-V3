local M = {}

function M.build_base(args)
  return {
    ts = args.ts,
    node_id = args.node_id,
    role = args.role,
    version = args.version,
    health = args.health,
    master_connected = args.master_connected,
    master_seen_s = args.master_seen_s,
    discovery_failed = args.discovery_failed,
    registry = args.registry,
    queue = args.queue,
    peers = args.peers,
    alerts = args.alerts,
    protocol_mismatch = args.protocol_mismatch,
    last_command = args.last_command,
    last_command_ts = args.last_command_ts
  }
end

return M
