-- core/update_handshake.lua
-- Shared runtime/update handshake between the role coroutine and updater.

local M = {}

M.STATE = {
  IDLE                 = "IDLE",
  UPDATE_REQUESTED     = "UPDATE_REQUESTED",
  QUIESCE_REQUESTED    = "QUIESCE_REQUESTED",
  SAFE_OUTPUTS_APPLIED = "SAFE_OUTPUTS_APPLIED",
  RUNTIME_STOPPED      = "RUNTIME_STOPPED",
}

function M.new()
  return {
    state = M.STATE.IDLE,
    requested_at = nil,
    remote_update_pending = false,
    remote_update_meta = nil,
  }
end

function M.request_quiesce(handshake)
  if type(handshake) ~= "table" then return false, "missing handshake" end
  -- A second request must never rewind a role that has already applied safe
  -- outputs or exited. This matters when a radio/manual request races a
  -- periodic version check.
  if handshake.state == M.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == M.STATE.RUNTIME_STOPPED then
    return true
  end
  handshake.state = M.STATE.UPDATE_REQUESTED
  handshake.state = M.STATE.QUIESCE_REQUESTED
  handshake.requested_at = os.epoch("utc")
  return true
end

function M.is_quiesce_requested(handshake)
  return handshake ~= nil and handshake.state == M.STATE.QUIESCE_REQUESTED
end

function M.mark_safe_outputs_applied(handshake)
  if handshake and handshake.state == M.STATE.QUIESCE_REQUESTED then
    handshake.state = M.STATE.SAFE_OUTPUTS_APPLIED
    return true
  end
  return false
end

function M.mark_runtime_stopped(handshake)
  if not handshake then return false end
  -- RUNTIME_STOPPED is only valid after the role explicitly proved its safe
  -- outputs. Callers cannot skip the safety state by invoking this helper
  -- from IDLE/QUIESCE_REQUESTED.
  if handshake.state ~= M.STATE.SAFE_OUTPUTS_APPLIED then return false end
  handshake.state = M.STATE.RUNTIME_STOPPED
  return true
end

function M.is_runtime_stopped(handshake)
  return handshake ~= nil and handshake.state == M.STATE.RUNTIME_STOPPED
end

function M.wait_for_runtime_stopped(handshake, timeout_s)
  if not handshake then return true end
  local deadline = os.epoch("utc") + (tonumber(timeout_s) or 20) * 1000
  while handshake.state ~= M.STATE.RUNTIME_STOPPED do
    if os.epoch("utc") >= deadline then return false end
    os.sleep(0.5)
  end
  return true
end

-- Queue a user/network initiated update for the updater coroutine. This does
-- not request quiesce by itself: the updater owns the complete transition
-- from queued request -> quiesce -> installer -> reboot.
function M.request_remote_update(handshake, meta)
  if type(handshake) ~= "table" then return false, "missing handshake" end
  if handshake.remote_update_pending then return true, "already queued" end
  handshake.remote_update_pending = true
  handshake.remote_update_meta = type(meta) == "table" and meta or {}
  handshake.remote_update_meta.queued_at = handshake.remote_update_meta.queued_at
    or (os.epoch and os.epoch("utc") or nil)
  if os and type(os.queueEvent) == "function" then
    pcall(os.queueEvent, "xreactor_remote_update_requested")
  end
  return true, "queued"
end

function M.peek_remote_update(handshake)
  if type(handshake) ~= "table" or handshake.remote_update_pending ~= true then return nil end
  return handshake.remote_update_meta or {}
end

function M.consume_remote_update(handshake)
  local meta = M.peek_remote_update(handshake)
  if not meta then return nil end
  handshake.remote_update_pending = false
  handshake.remote_update_meta = nil
  return meta
end

-- Reset only the runtime quiesce phase. A queued remote request is kept until
-- the updater explicitly consumes it, so a timeout cannot silently lose the
-- user's request.
function M.reset(handshake)
  if handshake then
    handshake.state = M.STATE.IDLE
    handshake.requested_at = nil
  end
end

return M
