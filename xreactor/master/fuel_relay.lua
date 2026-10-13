-- Relays fresh RT reactor fuel measurements to FUEL nodes.

local reactor_identity = require("core.reactor_identity")

local M = {}

-- Alle 10 s, ohne Quittung (Funk-Hygiene v821, Betreiberentscheidung).
-- FUEL hoert die RT-Statusmeldungen direkt mit (nodes/fuel/
-- fuel_status_network.lua's make_overhear_service) -- das Relais ist der
-- Rueckweg fuer den Fall, dass das nicht klappt. Bis v820 lief es alle 4 s
-- als quittiertes Kommando: je Lauf zwei Quittungen zurueck, eine davon mit
-- der kompletten Tabelle als Echo, alles als Rundruf an jeden Rechner der
-- Anlage. Eine neu auftauchende FUEL-Node bekommt den Stand weiterhin
-- sofort (nodes_changed unten), nicht erst nach dem Intervall.
local RELAY_INTERVAL_MS = 10000
local MAX_SAMPLE_AGE_MS = 60000
local MAX_REACTORS = 256

local function make_entry(source_node, reactor, local_id, global_id, sample_ts, age_ms)
  return {
    fuel_amount = reactor.fuel_amount,
    fuel_capacity = reactor.fuel_capacity,
    label = reactor.alias or reactor.name or global_id,
    source_node = source_node,
    local_reactor_id = local_id,
    global_reactor_id = global_id,
    ts = sample_ts,
    source_age_ms = age_ms,
  }
end

local function collect_reactor_fuel(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  local out, legacy_sources = {}, {}
  local reactor_count = 0

  for state_id, node in pairs(runtime.state.nodes or {}) do
    if reactor_count >= MAX_REACTORS then break end
    if node.role == constants.roles.RT_NODE and type(node.rt) == "table"
        and type(node.rt.reactors) == "table"
        and not node.stale and not node.offline then
      local source_node = node.id or state_id
      local sample_ts = tonumber(node.last_seen) or now
      local age_ms = math.max(0, now - sample_ts)
      if age_ms <= MAX_SAMPLE_AGE_MS then
        for _, reactor in ipairs(node.rt.reactors) do
          if reactor_count >= MAX_REACTORS then break end
          if type(reactor) == "table"
              and (reactor.fuel_amount ~= nil or reactor.fuel_capacity ~= nil) then
            local local_id, global_id = reactor_identity.resolve(source_node, reactor)
            if local_id and global_id then
              local entry = make_entry(
                tostring(source_node), reactor, local_id, global_id, sample_ts, age_ms)
              out[global_id] = entry
              reactor_count = reactor_count + 1

              local sources = legacy_sources[local_id]
              if not sources then sources = {}; legacy_sources[local_id] = sources end
              sources[tostring(source_node)] = entry
            end
          end
        end
      end
    end
  end

  -- Rolling-upgrade compatibility: retain a historical local ID only while
  -- exactly one fresh RT source owns it. On collision the alias is removed,
  -- preventing an arbitrary node from receiving the route.
  for local_id, sources in pairs(legacy_sources) do
    local count, only = 0, nil
    for _, entry in pairs(sources) do
      count = count + 1
      only = entry
      if count > 1 then break end
    end
    if count == 1 and out[local_id] == nil then out[local_id] = only end
  end

  return out
end

-- Stabiler Fingerabdruck der aktuell bekannten FUEL-Nodes. Taucht eine neu
-- auf (Kaltstart, Reboot), darf sie nicht bis zu RELAY_INTERVAL_MS auf
-- ihren ersten Fuellstand warten -- sie hat nach dem Boot gar keine Daten,
-- nicht nur leicht veraltete.
local function fuel_node_key(ids)
  table.sort(ids)
  return table.concat(ids, ",")
end

function M.tick(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  runtime.state._fuel_relay_last = runtime.state._fuel_relay_last or 0

  local fuel_nodes = {}
  for id, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.FUEL_NODE then fuel_nodes[#fuel_nodes + 1] = id end
  end
  if #fuel_nodes == 0 then
    runtime.state._fuel_relay_nodes = nil
    return
  end

  local node_key = fuel_node_key(fuel_nodes)
  local nodes_changed = node_key ~= runtime.state._fuel_relay_nodes
  if not nodes_changed and now - runtime.state._fuel_relay_last < RELAY_INTERVAL_MS then return end
  runtime.state._fuel_relay_nodes = node_key

  local snapshot = collect_reactor_fuel(runtime)
  runtime.state._fuel_relay_last = now
  for _, id in ipairs(fuel_nodes) do
    runtime.refs.comms:send_command(id, {
      target = constants.command_targets.FUEL_STATUS,
      value = snapshot,
    }, { no_ack = true })
  end
end

M._collect_reactor_fuel = collect_reactor_fuel

return M
