local M = {}
local utils = require("core.utils")

M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS = 1500
M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS = 60000  -- 60s cooldown after cancelled shutdown

-- Fix P3: payload_looks_rt jetzt in utils zentralisiert
local payload_looks_rt = utils.payload_looks_rt

local function bool_flag(value)
  return value and 'yes' or 'no'
end

function M.new(opts)
  local constants = assert(opts.constants, 'constants required')
  local utils = assert(opts.utils, 'utils required')
  local batch_window_ms = assert(tonumber(opts.batch_window_ms), 'batch_window_ms required')
  local sync_rt_node = assert(opts.sync_rt_node, 'sync_rt_node required')
  local log = assert(opts.log, 'log required')

  local pending = {}
  local skipped = {}
  local dirty_logged = {}

  local function node_looks_rt(node)
    if type(node) ~= 'table' then return false end
    if node.role == constants.roles.RT_NODE then return true end
    if type(node.rt) == 'table' then return true end
    if payload_looks_rt(node.payload) then return true end
    if type(node.turbines) == 'table' or type(node.reactors) == 'table' or type(node.modules) == 'table' then return true end
    if node.turbine_rpm ~= nil or node.steam ~= nil or node.ramp_state ~= nil then return true end
    return false
  end

  local function log_skip_once(node, reason)
    local node_id = tostring(node and (node.id or node.node_id or node.sender_id) or '?')
    local key = node_id .. '|' .. tostring(reason or 'unknown')
    if skipped[key] then return end
    skipped[key] = true
    local payload = type(node) == 'table' and node.payload or nil
    log(("RT sync skip node=%s role=%s reason=%s has_rt=%s payload_rt=%s payload_mode=%s payload_output=%s payload_turbines=%s payload_reactors=%s payload_modules=%s payload_keys=%s"):format(
      node_id,
      tostring(node and node.role or 'nil'),
      tostring(reason or 'unknown'),
      bool_flag(type(node) == 'table' and type(node.rt) == 'table'),
      bool_flag(type(payload) == 'table' and type(payload.rt) == 'table'),
      bool_flag(type(payload) == 'table' and payload.mode ~= nil),
      bool_flag(type(payload) == 'table' and payload.output ~= nil),
      bool_flag(type(payload) == 'table' and type(payload.turbines) == 'table'),
      bool_flag(type(payload) == 'table' and type(payload.reactors) == 'table'),
      bool_flag(type(payload) == 'table' and type(payload.modules) == 'table'),
      type(payload) == 'table' and tostring(#payload) or 'not-table'
    ), 'WARN')
  end

  local function mark_dirty(node, reason)
    if not node then return end
    if node.role ~= constants.roles.RT_NODE then
      if not node_looks_rt(node) then
        log_skip_once(node, reason)
        return
      end
      local previous = node.role
      node.role = constants.roles.RT_NODE
      log(("RT sync role inferred node=%s previous=%s reason=%s"):format(
        tostring(node.id or node.node_id or '?'), tostring(previous or 'UNKNOWN'), tostring(reason or 'unknown')
      ), 'INFO')
    end
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
      if not dirty_logged[node_id] then
        dirty_logged[node_id] = true
        log(("RT sync dirty queued node=%s reason=%s role=%s"):format(
          tostring(node_id), tostring(reason or 'unknown'), tostring(node.role or 'nil')
        ), 'INFO')
      end
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
      if force or age_ms >= batch_window_ms or idle_ms >= batch_window_ms then
        local reason_parts = {}
        for reason_name, enabled in pairs(slot.reasons or {}) do
          if enabled then reason_parts[#reason_parts + 1] = tostring(reason_name) end
        end
        table.sort(reason_parts)
        local reasons = table.concat(reason_parts, ',')
        log(("RT sync flush node=%s reasons=%s age_ms=%d idle_ms=%d force=%s trigger=%s"):format(
          tostring(node_id), tostring(reasons), tonumber(age_ms) or 0, tonumber(idle_ms) or 0, tostring(force),
          force and 'force' or ((age_ms >= batch_window_ms) and 'age' or 'idle')
        ), 'INFO')
        if slot.node and node_looks_rt(slot.node) then
          slot.node.role = constants.roles.RT_NODE
          sync_rt_node(slot.node, 'coalesced:' .. reasons)
        else
          log_skip_once(slot.node, 'flush')
        end
        pending[node_id] = nil
        dirty_logged[node_id] = nil
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
