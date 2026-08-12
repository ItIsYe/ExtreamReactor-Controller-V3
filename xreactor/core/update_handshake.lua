-- Shared state between a role runtime and the single managed updater.
--
-- Safety order:
--   IDLE -> QUIESCE_REQUESTED -> SAFE_OUTPUTS_APPLIED -> RUNTIME_STOPPED
--
-- A remote request is queued separately. Only installer/auto_update.lua may
-- consume it and start an installation.

local M = {}

M.UPDATE_EVENT = "xreactor_remote_update_requested"

M.STATE = {
  IDLE                 = "IDLE",
  UPDATE_REQUESTED     = "UPDATE_REQUESTED",
  QUIESCE_REQUESTED    = "QUIESCE_REQUESTED",
  SAFE_OUTPUTS_APPLIED = "SAFE_OUTPUTS_APPLIED",
  RUNTIME_STOPPED      = "RUNTIME_STOPPED",
}

local function now_ms()
  if os and type(os.epoch) == "function" then return os.epoch("utc") end
  return nil
end

function M.new()
  return {
    state = M.STATE.IDLE,
    requested_at = nil,
    quiesce_attempted = false,
    remote_update_pending = false,
    remote_update_meta = nil,
  }
end

function M.request_quiesce(handshake)
  if type(handshake) ~= "table" then return false, "missing handshake" end

  -- A concurrent/duplicate request must never rewind an already safe or
  -- stopped runtime.
  if handshake.state == M.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == M.STATE.RUNTIME_STOPPED then
    return true, "already safe"
  end
  if handshake.state ~= M.STATE.IDLE
      and handshake.state ~= M.STATE.UPDATE_REQUESTED
      and handshake.state ~= M.STATE.QUIESCE_REQUESTED then
    return false, "invalid handshake state"
  end

  if handshake.state == M.STATE.IDLE then handshake.quiesce_attempted = false end
  handshake.state = M.STATE.UPDATE_REQUESTED
  handshake.state = M.STATE.QUIESCE_REQUESTED
  handshake.requested_at = handshake.requested_at or now_ms()
  return true, "quiesce requested"
end

function M.mark_quiesce_attempted(handshake)
  if type(handshake) ~= "table"
      or handshake.state ~= M.STATE.QUIESCE_REQUESTED then
    return false
  end
  handshake.quiesce_attempted = true
  return true
end

function M.is_quiesce_requested(handshake)
  return type(handshake) == "table"
    and handshake.state == M.STATE.QUIESCE_REQUESTED
end

function M.mark_safe_outputs_applied(handshake)
  if type(handshake) ~= "table"
      or handshake.state ~= M.STATE.QUIESCE_REQUESTED then
    return false
  end
  handshake.state = M.STATE.SAFE_OUTPUTS_APPLIED
  return true
end

function M.mark_runtime_stopped(handshake)
  if type(handshake) ~= "table"
      or handshake.state ~= M.STATE.SAFE_OUTPUTS_APPLIED then
    return false
  end
  handshake.state = M.STATE.RUNTIME_STOPPED
  return true
end

function M.wait_for_runtime_stopped(handshake, timeout_s)
  -- Compatibility for callers which intentionally run without managed
  -- updating. The managed updater itself rejects a missing handshake before
  -- reaching this helper.
  if handshake == nil then return true end
  if type(handshake) ~= "table" then return false end
  if not os or type(os.epoch) ~= "function" or type(os.sleep) ~= "function" then
    return false
  end
  local deadline = os.epoch("utc") + (tonumber(timeout_s) or 20) * 1000
  while handshake.state ~= M.STATE.RUNTIME_STOPPED do
    if os.epoch("utc") >= deadline then return false end
    os.sleep(0.5)
  end
  return true
end

function M.request_remote_update(handshake, meta)
  if type(handshake) ~= "table" then return false, "missing handshake" end
  if handshake.remote_update_pending == true then return true, "already queued" end

  local source = type(meta) == "table" and meta or {}
  handshake.remote_update_pending = true
  handshake.remote_update_meta = {
    source = source.source,
    message_id = source.message_id,
    trigger = source.trigger,
    queued_at = source.queued_at or now_ms(),
  }
  if os and type(os.queueEvent) == "function" then
    pcall(os.queueEvent, M.UPDATE_EVENT)
  end
  return true, "queued"
end

function M.peek_remote_update(handshake)
  if type(handshake) ~= "table"
      or handshake.remote_update_pending ~= true then
    return nil
  end
  return handshake.remote_update_meta or {}
end

function M.consume_remote_update(handshake)
  local meta = M.peek_remote_update(handshake)
  if not meta then return nil end
  handshake.remote_update_pending = false
  handshake.remote_update_meta = nil
  return meta
end

-- Only cancel a request while the role is still running. Once safe outputs
-- were applied, recovery requires rebooting the stopped runtime.
function M.reset(handshake)
  if type(handshake) ~= "table" then return false end
  if handshake.state == M.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == M.STATE.RUNTIME_STOPPED then
    return false
  end
  handshake.state = M.STATE.IDLE
  handshake.requested_at = nil
  handshake.quiesce_attempted = false
  return true
end

return M
