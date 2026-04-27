local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local master_cfg = read("xreactor/master/config.lua")
local energy_cfg = read("xreactor/nodes/energy/config.lua")

local checks = {
  { source = master_cfg, snippet = "DEFAULT_COMMS_PEER_DOWN_GRACE = 3.0" },
  { source = master_cfg, snippet = "DEFAULT_COMMS_PEER_UP_DEBOUNCE = 2.5" },
  { source = master_cfg, snippet = "DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS = 3" },
  { source = energy_cfg, snippet = "DEFAULT_COMMS_PEER_DOWN_GRACE = 3.0" },
  { source = energy_cfg, snippet = "DEFAULT_COMMS_PEER_UP_DEBOUNCE = 2.5" },
  { source = energy_cfg, snippet = "DEFAULT_COMMS_PEER_UP_MIN_OBSERVATIONS = 3" },
  { source = energy_cfg, snippet = "DEFAULT_MATRIX_METRIC_POLL_INTERVAL = 3.0" }
}

for _, check in ipairs(checks) do
  if not check.source:find(check.snippet, 1, true) then
    error("missing comms stability default: " .. tostring(check.snippet))
  end
end

print("comms_stability_defaults_regression_test.lua: ok")
