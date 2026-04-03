local function read(path)
  local handle = io.open(path, "r")
  if not handle then
    error("unable to read " .. tostring(path))
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local main_src = read("xreactor/nodes/rt/main.lua")
local fn_start = main_src:find("local function read_turbine_flow%(", 1)
if not fn_start then
  error("read_turbine_flow function missing")
end
local fn_end = main_src:find("return nil, \"FLOW_UNAVAILABLE\"", fn_start, true)
if not fn_end then
  error("read_turbine_flow function end marker missing")
end
local fn_body = main_src:sub(fn_start, fn_end)
local max_idx = fn_body:find("getFluidFlowRateMax", 1, true)
local flow_idx = fn_body:find("getFluidFlowRate\"", 1, true)
if not max_idx or not flow_idx then
  error("missing turbine flow readback APIs in read_turbine_flow")
end
if max_idx > flow_idx then
  error("read_turbine_flow must prefer getFluidFlowRateMax before getFluidFlowRate to avoid false floor diagnostics")
end

print("rt_turbine_readback_source_regression_test.lua: ok")
