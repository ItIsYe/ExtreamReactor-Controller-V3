-- Builds the reactor target list shown by the FUEL route editor.

local M = {}

function M.collect(config, fuel_status_cache, comms, constants)
  local list, by_id = {}, {}

  local function add(id, label)
    if id == nil then return end
    id = tostring(id)
    if id == "" then return end
    label = tostring(label or id)
    local existing = by_id[id]
    if existing then
      if (existing.label == existing.id or existing.label == "") and label ~= id then
        existing.label = label
      end
      return
    end
    local entry = { id = id, label = label }
    by_id[id] = entry
    list[#list + 1] = entry
  end

  local logistics = type(config) == "table" and type(config.logistics) == "table"
    and config.logistics or {}

  for _, entry in ipairs(logistics.reactors or {}) do
    if type(entry) == "table" then
      local id = entry.reactor_id or entry.reactor_port or entry.id or entry.label or entry.name
      add(id, entry.name or entry.label or id)
    end
  end

  for _, route in ipairs(logistics.redstone_tree or {}) do
    if type(route) == "table" then add(route.reactor or route.label, route.label or route.reactor) end
  end

  local function add_from_cache(cache)
    if type(cache) ~= "table" then return end
    for cache_id, entry in pairs(cache) do
      if type(entry) == "table" then
        local id = entry.global_reactor_id or cache_id
        add(id, entry.label or id)
      end
    end
  end
  if type(fuel_status_cache) == "table" then
    add_from_cache(fuel_status_cache.master_relay)
    add_from_cache(fuel_status_cache.direct_heard)
  end

  if #list == 0 and comms and type(comms.get_peers) == "function" then
    local ok, peers = pcall(comms.get_peers, comms)
    if ok and type(peers) == "table" then
      for peer_id, peer in pairs(peers) do
        if type(peer) == "table" and peer.role == constants.roles.RT_NODE and peer.down ~= true then
          add(peer_id, peer_id)
        end
      end
    end
  end

  table.sort(list, function(a, b)
    local al, bl = tostring(a.label):lower(), tostring(b.label):lower()
    if al ~= bl then return al < bl end
    return tostring(a.id) < tostring(b.id)
  end)
  return list
end

return M
