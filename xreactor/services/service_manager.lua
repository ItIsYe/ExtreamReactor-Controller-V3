local utils = require("core.utils")

local manager = {}

function manager.new(opts)
  opts = opts or {}
  local self = {
    services = {},
    log_prefix = opts.log_prefix or "SERVICES",
    running = false
  }
  return setmetatable(self, { __index = manager })
end

function manager:add(service)
  table.insert(self.services, service)
end

function manager:init()
  for _, service in ipairs(self.services) do
    if service.init then
      local ok, err = pcall(service.init, service)
      if not ok then
        utils.log(self.log_prefix, "Service init failed: " .. tostring(err), "ERROR")
      end
    end
  end
  self.running = true
end

function manager:tick(dt, event)
  for _, service in ipairs(self.services) do
    if service.tick then
      local ok, err = pcall(service.tick, service, dt, event)
      if not ok then
        utils.log(self.log_prefix, "Service tick failed: " .. tostring(err), "ERROR")
      end
    end
  end
end

function manager:stop()
  for _, service in ipairs(self.services) do
    if service.stop then
      local ok, err = pcall(service.stop, service)
      if not ok then
        utils.log(self.log_prefix, "Service stop failed: " .. tostring(err), "ERROR")
      end
    end
  end
  self.running = false
end

return manager
