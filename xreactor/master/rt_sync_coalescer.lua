local M = {}

function M.new(opts)
  local constants = assert(opts.constants, 'constants required')
  local utils = assert(opts.utils, 'utils required')
  local batch_window_ms = assert(tonumber(opts.batch_window_ms), 'batch_window_ms required')
  local sync_rt_node = assert(opts.sync_rt_node, 'sync_rt_node required')
  local log = assert(opts.log, 'log required')

  local pending = {}

  local function mark_dirty(node, reason)
    if not node or node.role ~= constants.roles.RT_NODE then return end
    local node_id = utils.normalize_node_id(node.id)
    local now = os.epoch('utc')
    local slot = pending[node_id]
    if not slot then
      pending[node_id] = {
        node = node,
        first_at = now,
        last_at = now,
        reasons = { [tostring(reason or 'unknown')] = true }
      }
      return
    end
    slot.node = node
    slot.last_at = now
    slot.reasons[tostring(reason or 'unknown')] = true
  end

  local function flush(opts2)
    opts2 = opts2 or {}
    local force = opts2.force == true
    local now = os.epoch('utc')
    for node_id, slot in pairs(pending) do
      local age_ms = now - (slot.first_at or now)
      local idle_ms = now - (slot.last_at or slot.first_at or now)
      if force or idle_ms >= batch_window_ms then
        local reason_parts = {}
        for reason_name, enabled in pairs(slot.reasons or {}) do
          if enabled then reason_parts[#reason_parts + 1] = tostring(reason_name) end
        end
        table.sort(reason_parts)
        local reasons = table.concat(reason_parts, ',')
        log(("RT sync flush node=%s reasons=%s age_ms=%d idle_ms=%d force=%s"):format(
          tostring(node_id), tostring(reasons), tonumber(age_ms) or 0, tonumber(idle_ms) or 0, tostring(force)
        ), 'INFO')
        if slot.node and slot.node.role == constants.roles.RT_NODE then
          sync_rt_node(slot.node, 'coalesced:' .. reasons)
        end
        pending[node_id] = nil
      end
    end
  end

  local function size()
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
  end

  return {
    mark_dirty = mark_dirty,
    flush = flush,
    size = size
  }
end

return M
