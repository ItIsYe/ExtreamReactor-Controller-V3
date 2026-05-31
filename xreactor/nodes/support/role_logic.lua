local M = {}

function M.master_peer_state(comms, master_role)
  local peers = comms and comms:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == master_role then
      return data
    end
  end
  return nil
end

function M.is_master_connected(opts)
  local peer = M.master_peer_state(opts.comms, opts.master_role)
  if peer then
    return not peer.down, peer.age
  end
  if opts.last_seen_ts then
    local age = (os.epoch("utc") - opts.last_seen_ts) / 1000
    return age <= opts.heartbeat_interval * 6, age
  end
  return false, nil
end

return M
