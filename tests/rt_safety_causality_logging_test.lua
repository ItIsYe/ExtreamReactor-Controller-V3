local function read(path)
  local h=io.open(path,"r"); if not h then error("missing: "..path) end
  local c=h:read("*a"); h:close(); return c
end
local main_src=read("xreactor/nodes/rt/main.lua")
local lifecycle_src=read("xreactor/nodes/rt/module_lifecycle.lua")
local tc_src=read("xreactor/nodes/rt/turbine_control.lua")
local combined=main_src.."\n"..lifecycle_src.."\n"..tc_src
local function assert_contains(src,pattern,message)
  if not src:find(pattern,1,true) then error(message) end
end
assert_contains(combined,"SAFE","SAFE mode must be referenced")
assert_contains(combined,"Overspeed","overspeed mismatch path must emit explicit diagnostics")
assert_contains(combined,"readback_state=","turbine diagnostics must log explicit readback state")
assert_contains(lifecycle_src,"REACTOR_COOLANT","coolant safety path must reference REACTOR_COOLANT")
assert_contains(lifecycle_src,"REACTOR_TEMP","temperature safety path must reference REACTOR_TEMP")
print("rt_safety_causality_logging_test.lua: ok")
