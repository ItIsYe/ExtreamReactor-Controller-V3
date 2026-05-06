local M = {}

M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS = 1500
M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS = 15000

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


function M.advance_shutdown_candidate(opts)
  local workflow = assert(opts.workflow, 'workflow required')
  local now = assert(tonumber(opts.now), 'now required')
  local is_candidate = opts.is_candidate == true
  local restart_cooldown_ms = tonumber(opts.restart_cooldown_ms) or M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS
  local stability_ms = tonumber(opts.stability_ms) or M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS

  if is_candidate then
    if workflow.stage == "CANCELLED_DEMAND_RECOVERED" and workflow.cancelled_at and (now - workflow.cancelled_at) >= restart_cooldown_ms and not workflow.requested_at then
      workflow.shutdown_candidate_since = now
      workflow.stage = nil
      workflow.final_reason = nil
      workflow.outcome = nil
      workflow.completed_at = nil
      workflow.error = nil
      return { action = 'candidate_reset' }
    end
    workflow.shutdown_candidate_since = workflow.shutdown_candidate_since or now
    local candidate_age_ms = now - workflow.shutdown_candidate_since
    if workflow.cancelled_at and (now - workflow.cancelled_at) < restart_cooldown_ms then
      workflow.shutdown_candidate_since = now
      return { action = 'debounce_cooldown', remaining_ms = math.max(0, restart_cooldown_ms - (now - workflow.cancelled_at)) }
    end
    if candidate_age_ms < stability_ms then
      return { action = 'debounce_stability', remaining_ms = math.max(0, stability_ms - candidate_age_ms) }
    end
    if not workflow.requested_at then
      return { action = 'start_requested' }
    end
    return { action = 'candidate_active' }
  end

  if workflow.requested_at and workflow.stage ~= "COMPLETED" and workflow.stage ~= "FAILED" and workflow.stage ~= "CANCELLED_DEMAND_RECOVERED" then
    workflow.stage = "CANCELLED_DEMAND_RECOVERED"
    workflow.final_reason = "CANCELLED_DEMAND_RECOVERED"
    workflow.error = nil
    workflow.outcome = "CANCELLED"
    workflow.state_reached_at = nil
    workflow.completed_at = now
    workflow.cancelled_at = now
    workflow.requested_at = nil
    return { action = 'cancelled' }
  end

  workflow.shutdown_candidate_since = nil
  return { action = 'idle' }
end

return M
