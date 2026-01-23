local utils = require("core.utils")

local telemetry = {}

function telemetry.new(opts)
  opts = opts or {}
  local self = {
    log_prefix = opts.log_prefix or "TELEMETRY",
    comms = opts.comms,
    build_payload = opts.build_payload,
    heartbeat_state = opts.heartbeat_state,
    status_interval = opts.status_interval or 5,
    heartbeat_interval = opts.heartbeat_interval or 2,
    last_status = 0,
    last_heartbeat = 0
  }
  return setmetatable(self, { __index = telemetry })
end

local function now()
  return os.epoch("utc")
end

function telemetry:tick()
  local ts = now()
  if ts - self.last_heartbeat >= self.heartbeat_interval * 1000 then
    self.last_heartbeat = ts
    if self.heartbeat_state then
      self.comms:send_heartbeat(self.heartbeat_state())
    else
      self.comms:send_heartbeat({})
    end
  end
  if ts - self.last_status >= self.status_interval * 1000 then
    self.last_status = ts
    if self.build_payload then
      local ok, payload = pcall(self.build_payload)
      if ok and payload then
        self.comms:publish_status(payload, { requires_ack = true })
      elseif not ok then
        utils.log(self.log_prefix, "Status payload error: " .. tostring(payload), "WARN")
      end
    end
  end
end

return telemetry
