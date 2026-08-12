-- Persistent RT capacity-learning cache.

local utils = require("core.utils")
local M = {}

function M.save(learning, opts)
  if type(learning) ~= "table" or learning.ready ~= true then
    return false, "not ready"
  end
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return false, "no path" end

  return utils.write_config(opts.path, {
    ready = true,
    max_output = tonumber(learning.max_output) or 0,
    turbine_count = tonumber(opts.turbine_count) or 0,
    reason = tostring(learning.reason or "LOADED_FROM_CACHE"),
    topology_signature = learning.topology_signature,
    topology_generation = tonumber(learning.topology_generation) or 0,
    topology_changed_at = tonumber(learning.topology_changed_at),
  })
end

function M.load(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" or not fs.exists(opts.path) then
    return nil
  end

  local data = utils.load_config(opts.path, {})
  if type(data) ~= "table" or data.ready ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end
  if type(opts.topology_signature) == "string"
      and data.topology_signature ~= opts.topology_signature then
    local log = type(opts.log) == "function" and opts.log or function() end
    pcall(log, "WARN", "Capacity cache rejected: hardware topology changed")
    return nil
  end

  data.reason = data.reason or "LOADED_FROM_CACHE"
  data.topology_generation = tonumber(data.topology_generation) or 0
  data.dirty = false
  return data
end

return M
