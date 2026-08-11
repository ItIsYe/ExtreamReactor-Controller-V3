-- nodes/fuel/fuel_status_network.lua
-- Network-backed reactor fuel-level cache for the FUEL node.

local protocol = require("core.protocol")
local M = {}

function M.new()
  return {
    master_relay = {},
    direct_heard = {},
    -- Legacy local reactor IDs are accepted only while one RT source owns
    -- them. Once two sources collide, that alias remains blocked for the
    -- current boot and only node-scoped global IDs are usable.
    direct_legacy_source = {},
    direct_collisions = {},
  }
end

function M.ingest_master_relay(cache, value)
  if type(value) ~= "table" then return end
  local now = os.epoch("utc")
  for reactor_id, entry in pairs(value) do
    if type(entry) == "table" then
      local age_ms = math.max(0, tonumber(entry.source_age_ms) or 0)
      cache.master_relay[reactor_id] = {
        fuel_amount = entry.fuel_amount,
        fuel_capacity = entry.fuel_capacity,
        label = entry.label,
        ts = now - age_ms,
        source_node = entry.source_node,
        local_reactor_id = entry.local_reactor_id,
        global_reactor_id = entry.global_reactor_id,
      }
    end
  end
end

local function store_direct(cache, message, reactor, now)
  local source = message.src or message.sender_id or message.node_id
  if type(source) ~= "string" or source == "" then return end
  local local_id = reactor.local_id or reactor.id
  if local_id == nil then return end
  local_id = tostring(local_id)
  local global_id = reactor.global_id
  if type(global_id) ~= "string" or global_id == "" then
    global_id = source .. ":" .. local_id
  end
  local entry = {
    fuel_amount = reactor.fuel_amount,
    fuel_capacity = reactor.fuel_capacity,
    label = reactor.alias or reactor.name or global_id,
    ts = now,
    source_node = source,
    local_reactor_id = local_id,
    global_reactor_id = global_id,
  }
  cache.direct_heard[global_id] = entry

  if cache.direct_collisions[local_id] then return end
  local previous_source = cache.direct_legacy_source[local_id]
  if previous_source == nil or previous_source == source then
    cache.direct_legacy_source[local_id] = source
    cache.direct_heard[local_id] = entry
    return
  end

  cache.direct_collisions[local_id] = true
  cache.direct_heard[local_id] = nil
end

function M.make_overhear_service(cache, constants)
  return {
    name = "fuel_status_overhear",
    wants_events = true,
    tick = function(_self, dt, event)
      if not (event and event[1] == "modem_message") then return end
      local raw = event[5]
      if type(raw) ~= "table" then return end

      -- This fallback runs outside comms_service, so it must perform the
      -- same envelope validation explicitly. Previously type/role strings
      -- alone were enough to inject fuel values into a delivery decision.
      local message = protocol.sanitize_message(raw)
      local valid = message and select(1, protocol.validate(message))
      if valid ~= true then return end
      if message.type ~= constants.message_types.STATUS then return end
      if message.role ~= constants.roles.RT_NODE then return end
      local source = message.src or message.sender_id or message.node_id
      if type(source) ~= "string" or source == "" then return end

      local reactors = message.payload and message.payload.reactors
      if type(reactors) ~= "table" then return end
      local now = os.epoch("utc")
      for _, r in ipairs(reactors) do
        if type(r) == "table" and r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
          store_direct(cache, message, r, now)
        end
      end
    end
  }
end

return M
