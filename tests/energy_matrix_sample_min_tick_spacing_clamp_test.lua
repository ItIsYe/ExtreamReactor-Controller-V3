-- matrix_sample_min_tick_spacing_ms war der einzige matrix_*-Tuning-Wert
-- ohne clamp_num()-Validierung in config_normalizer.lua: ein grosser
-- Fehlwert (z.B. versehentlich 999999 statt 400) konnte das Matrix-Sampling
-- unbemerkt auf Minuten verlangsamen, ohne jede Warnung. Muss jetzt wie
-- jeder andere matrix_metric_*-Wert geclampt werden.

local normalizer = dofile("xreactor/nodes/energy/config_normalizer.lua")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq failed") .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
  end
end

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
  node_id = "ENERGY-1", role = "ENERGY", debug_logging = true, reset_log_on_start = true,
  wireless_modem = nil, wired_modem = nil, matrix = nil,
  matrix_names = {}, matrix_aliases = {}, cubes = {},
  scan_interval = 2, discovery_force_rescan_interval = 300,
  matrix_metric_poll_interval = 3.0, matrix_metric_call_budget = 6,
  matrix_metric_time_budget_ms = 2000, matrix_metric_slow_call_ms = 400,
  matrix_metric_slow_poll_multiplier = 4.0, matrix_metric_per_matrix_budget = 1,
  matrix_sample_min_tick_spacing_ms = 400,
  matrix_component_poll_interval = 30, matrix_component_call_budget = 2,
  matrix_component_time_budget_ms = 2000,
  ui_refresh_interval = 1.0, ui_scale = 0.5,
  monitor = { preferred_name = nil, strategy = "largest" },
  storage_filters = { include_names = nil, exclude_names = {}, prefer_names = {} },
  heartbeat_interval = 2, status_interval = 5,
  channels = { control = 1, status = 2 },
  comms = {},
}

local function make_config(overrides)
  local cfg = deep_copy(defaults)
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  return cfg
end

-- 1) Grober Fehlwert weit oberhalb sinnvoller Grenzen wird geclampt, nicht
--    unveraendert uebernommen.
local warnings1 = {}
local cfg1 = make_config({ matrix_sample_min_tick_spacing_ms = 999999 })
normalizer.normalize(cfg1, defaults, utils, function(w) table.insert(warnings1, w) end)
assert_eq(cfg1.matrix_sample_min_tick_spacing_ms, 10000, "oversized value must be clamped to the max")
local saw_warning1 = false
for _, w in ipairs(warnings1) do
  if w:find("matrix_sample_min_tick_spacing_ms", 1, true) then saw_warning1 = true end
end
assert(saw_warning1, "clamping must emit a warning naming the field")

-- 2) Fehlender/ungueltiger Wert faellt auf den Default zurueck.
local cfg2 = make_config({ matrix_sample_min_tick_spacing_ms = "not-a-number" })
normalizer.normalize(cfg2, defaults, utils, function() end)
assert_eq(cfg2.matrix_sample_min_tick_spacing_ms, 400, "invalid value must default to 400")

-- 3) Ein sinnvoller Wert im gueltigen Bereich bleibt unveraendert.
local cfg3 = make_config({ matrix_sample_min_tick_spacing_ms = 250 })
normalizer.normalize(cfg3, defaults, utils, function() end)
assert_eq(cfg3.matrix_sample_min_tick_spacing_ms, 250, "an in-range value must pass through unchanged")

print("energy_matrix_sample_min_tick_spacing_clamp_test.lua: ok")
