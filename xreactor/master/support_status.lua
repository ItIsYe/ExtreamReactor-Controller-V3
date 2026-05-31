local M = {}

local function copy_payload(payload)
  local out = {}
  if type(payload) ~= "table" then return out end
  for k, v in pairs(payload) do
    out[k] = v
  end
  return out
end

function M.apply(node, payload, constants)
  if type(node) ~= "table" or type(payload) ~= "table" or type(constants) ~= "table" then
    return
  end

  if node.role == constants.roles.WATER_NODE then
    local water = copy_payload(payload)
    water.total = water.total_water or water.total or 0
    water.buffers = water.buffers or {}
    water.state = water.state or (water.master_connected == false and "DEGRADED" or "OK")
    node.water = water
    return
  end

  if node.role == constants.roles.FUEL_NODE then
    local fuel = copy_payload(payload)
    fuel.amount = fuel.reserve or fuel.amount or 0
    fuel.minimum = fuel.minimum_reserve or fuel.minimum or 0
    fuel.sources = fuel.sources or {}
    fuel.state = fuel.state or (fuel.master_connected == false and "DEGRADED" or "OK")
    node.fuel = fuel
    return
  end

  if node.role == constants.roles.REPROCESSOR_NODE then
    local reprocessor = copy_payload(payload)
    reprocessor.state = reprocessor.state or (reprocessor.standby and "STANDBY" or "RUNNING")
    reprocessor.mode = reprocessor.mode or reprocessor.state
    reprocessor.buffers = reprocessor.buffers or {}
    node.reprocessor = reprocessor
  end
end

return M
