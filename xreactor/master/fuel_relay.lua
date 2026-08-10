-- master/fuel_relay.lua
-- Relays RT reactor fuel measurements to FUEL nodes.

local M = {}

local RELAY_INTERVAL_MS = 10000
local MAX_SAMPLE_AGE_MS = 60000

local function make_entry(node, reactor, sample_ts, age_ms)
  return {
    fuel_amount = reactor.fuel_amount,
    fuel_capacity = reactor.fuel_capacity,
    label = reactor.alias or reactor.name or reactor.global_id or reactor.id,
    source_node = node.id,
    local_reactor_id = reactor.local_id or reactor.id,
    global_reactor_id = reactor.global_id,
    ts = sample_ts,
    source_age_ms = age_ms,
  }
end

local function collect_reactor_fuel(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  local out = {}
  local legacy_sources = {}

  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.RT_NODE and type(node.rt) == "table"
        and type(node.rt.reactors) == "table"
        and not node.stale and not node.offline then
      local sample_ts = node.last_seen or now
      local age_ms = now - sample_ts
      if age_ms <= MAX_SAMPLE_AGE_MS then
        for _, r in ipairs(node.rt.reactors) do
          if r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
            local local_id = tostring(r.local_id or r.id)
            local global_id = r.global_id
            if type(global_id) ~= "string" or global_id == "" then
              -- Compatibility with an older RT that does not yet publish
              -- global_id. The source node is part of the identity, so two
              -- identical local registry IDs on different RT computers can
              -- no longer overwrite each other.
              global_id = tostring(node.id) .. ":" .. local_id
            end
            local entry = make_entry(node, r, sample_ts, age_ms)
            entry.global_reactor_id = global_id
            out[global_id] = entry

            -- Keep the historical local-id alias only while it is provably
            -- unambiguous across the currently fresh RT fleet. If a second
            -- source uses the same local id, the legacy alias is removed and
            -- FUEL must use the node-scoped global id. This fails closed
            -- instead of silently selecting whichever node happened to be
            -- iterated last.
            local sources = legacy_sources[local_id]
            if not sources then
              sources = {}
              legacy_sources[local_id] = sources
            end
            sources[tostring(node.id)] = entry
          end
        end
      end
    end
  end

  for local_id, sources in pairs(legacy_sources) do
    local count, only = 0, nil
    for _, entry in pairs(sources) do
      count = count + 1
      only = entry
      if count > 1 then break end
    end
    if count == 1 and out[local_id] == nil then
      out[local_id] = only
    else
      out[local_id] = nil
    end
  end

  return out
end

function M.tick(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  runtime.state._fuel_relay_last = runtime.state._fuel_relay_last or 0
  if (now - runtime.state._fuel_relay_last) < RELAY_INTERVAL_MS then return end

  local fuel_nodes = {}
  for id, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.FUEL_NODE then fuel_nodes[#fuel_nodes + 1] = id end
  end
  if #fuel_nodes == 0 then return end

  local snapshot = collect_reactor_fuel(runtime)
  runtime.state._fuel_relay_last = now

  for _, id in ipairs(fuel_nodes) do
    runtime.refs.comms:send_command(id, {
      target = constants.command_targets.FUEL_STATUS,
      value = snapshot,
    })
  end
end

return M
