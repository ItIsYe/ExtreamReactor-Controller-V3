local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local rt_main = read("xreactor/nodes/rt/main.lua")

if rt_main:find("if not caps.setInductorEngaged then", 1, true) and rt_main:find("warn_unsupported(name)", 1, true) then
  error("inductor capability must not hard-fail turbine support checks")
end

if not rt_main:find("missing-flow-setter", 1, true) then
  error("expected explicit unsupported reason for missing flow setter")
end

if not rt_main:find("bottleneck=", 1, true) then
  error("expected turbine diagnostics to include bottleneck classification")
end

print("rt_turbine_api_warning_regression_test.lua: ok")
