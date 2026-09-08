-- config.clusters wurde bisher ungeprueft durchgereicht: ein nicht-
-- tabellarischer Wert (z.B. versehentlich ein String) liess main.lua's
-- ipairs(config.clusters or {}) crashen, weil nur nil/false auf {}
-- zurueckfielen. Ein Cluster-Eintrag ohne gueltigen Tanknamen oder mit
-- min_volume > max_volume fuehrte zu Fill/Drain-Logik, die entweder nie
-- greift oder dauerhaft blockiert. config_normalizer.lua muss clusters
-- jetzt genau wie loop_tanks/target_volume zentral validieren.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local normalizer = dofile("xreactor/nodes/water/config_normalizer.lua")

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = deep_copy(v) end
  return out
end

local utils = {
  normalize_node_id = function(id) return type(id) == "string" and id ~= "" and id or "UNKNOWN" end,
  deep_copy = deep_copy,
}

local defaults = {
  node_id = "WATER-1", role = "WATER-NODE", debug_logging = true, reset_log_on_start = true,
  wireless_modem = nil, wired_modem = nil,
  heartbeat_interval = 2, status_interval = 5, discovery_interval = 15,
  channels = { control = 6500, status = 6501 }, comms = {},
  loop_tanks = { "dynamicTank_0" }, target_volume = 200000,
  balance_log_interval_s = 60, clusters = {},
}

local function normalize(overrides)
  local config = {
    node_id = "WATER-1", role = "WATER-NODE", debug_logging = true, reset_log_on_start = true,
    loop_tanks = { "dynamicTank_0" }, target_volume = 200000, balance_log_interval_s = 60,
  }
  for k, v in pairs(overrides) do config[k] = v end
  local warnings = {}
  normalizer.normalize(config, defaults, function(msg) warnings[#warnings + 1] = msg end, utils)
  return config, warnings
end

-- Fall 1: clusters ist gar keine Tabelle (z.B. versehentlich ein String) --
-- muss auf die leere Standardliste zurueckfallen statt main.lua's ipairs()
-- crashen zu lassen.
local cfg1, warn1 = normalize({ clusters = "oops" })
if type(cfg1.clusters) ~= "table" then
  error("clusters must fall back to a table when given a non-table value")
end
if #cfg1.clusters ~= 0 then
  error("clusters must fall back to an empty list for an invalid top-level value")
end
if #warn1 == 0 then
  error("expected a warning when clusters is not a table")
end

-- Fall 2: ein Cluster-Eintrag ohne gueltigen Tanknamen wird verworfen, ein
-- gueltiger bleibt erhalten.
local cfg2, warn2 = normalize({
  clusters = {
    { name = "Good", tank = "dynamicTank_1", min_volume = 100, max_volume = 200 },
    { name = "NoTank" },
  },
})
if #cfg2.clusters ~= 1 or cfg2.clusters[1].name ~= "Good" then
  error("expected only the cluster with a valid tank to survive normalization")
end
local found_notank_warning = false
for _, w in ipairs(warn2) do
  if w:find("NoTank") then found_notank_warning = true end
end
if not found_notank_warning then
  error("expected a warning naming the cluster missing a valid tank")
end

-- Fall 3: min_volume > max_volume wird verworfen (sonst blockiert/loest nie
-- sauber aus).
local cfg3, warn3 = normalize({
  clusters = { { name = "Inverted", tank = "dynamicTank_2", min_volume = 500, max_volume = 100 } },
})
if #cfg3.clusters ~= 0 then
  error("expected the inverted min_volume > max_volume cluster to be dropped")
end
if #warn3 == 0 then
  error("expected a warning for min_volume > max_volume")
end

-- Fall 4: eine vollstaendig gueltige Cluster-Liste bleibt unveraendert und
-- erzeugt keine Cluster-bezogenen Warnungen.
local cfg4, warn4 = normalize({
  clusters = { { name = "A", tank = "t1", min_volume = 100, max_volume = 200 } },
})
if #cfg4.clusters ~= 1 then
  error("expected a valid cluster list to pass through unchanged")
end
for _, w in ipairs(warn4) do
  if w:find("cluster") then
    error("did not expect a cluster-related warning for a fully valid config, got: " .. w)
  end
end

print('water_clusters_config_validation_test.lua: ok')
