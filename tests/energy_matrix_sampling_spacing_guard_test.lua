local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local main_src = read("xreactor/nodes/energy/main.lua")
local runtime_src = read("xreactor/nodes/energy/matrix_snapshot_runtime.lua")

if not main_src:find("matrix_sample_min_tick_spacing_ms", 1, true) then
  error("missing ENERGY config field for matrix sample tick spacing")
end
if not main_src:find("interval = 0.75", 1, true) then
  error("missing MATRIX_SAMPLE interval pacing guard")
end
if not runtime_src:find("min_tick_spacing_ms", 1, true) then
  error("missing runtime tick spacing variable")
end
if not runtime_src:find("now_ts - (self.last_poll_ts or 0)", 1, true) then
  error("missing runtime tick spacing comparison")
end

print("energy_matrix_sampling_spacing_guard_test.lua: ok")
