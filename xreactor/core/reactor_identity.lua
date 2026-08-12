-- Shared reactor identity rules for RT, MASTER and FUEL.
--
-- Registry device IDs are only unique inside one RT computer. Routing uses
-- "<node_id>:<local_reactor_id>" so identical reactor peripherals on two RT
-- nodes cannot overwrite each other. A published global ID is accepted only
-- when it matches the source node and local ID which carried it.

local utils = require("core.utils")

local M = {}

local function non_empty(value)
  if value == nil then return nil end
  local text = tostring(value)
  if text == "" then return nil end
  return text
end

function M.compose(node_id, local_id)
  local node = non_empty(node_id)
  local device = non_empty(local_id)
  if not node then return nil, "missing_node_id" end
  if not device then return nil, "missing_local_reactor_id" end

  node = utils.normalize_node_id(node)
  if node:lower() == "unknown" then return nil, "invalid_node_id" end
  return node .. ":" .. device
end

function M.resolve(node_id, reactor)
  if type(reactor) ~= "table" then return nil, nil, "invalid_reactor" end
  local local_id = non_empty(reactor.local_id or reactor.id)
  local global_id, err = M.compose(node_id, local_id)
  if not global_id then return nil, nil, err end

  local published = non_empty(reactor.global_id or reactor.global_reactor_id)
  if published and published ~= global_id then
    return nil, nil, "global_id_mismatch"
  end
  return local_id, global_id
end

function M.valid_transport_key(key, local_id, global_id)
  local normalized = non_empty(key)
  return normalized ~= nil and (normalized == local_id or normalized == global_id)
end

return M
