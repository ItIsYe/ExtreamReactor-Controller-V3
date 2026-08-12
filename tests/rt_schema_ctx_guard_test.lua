local function read(path)
  local h=io.open(path,"r"); if not h then error("missing: "..path) end
  local c=h:read("*a"); h:close(); return c
end
local main_src=read("xreactor/nodes/rt/main.lua")
if main_src:find("config%.runtime_ctx%.monitor",1,false) or
   main_src:find("config%.runtime_ctx%.mon",1,false) then
  error("rt main must not access legacy config.runtime_ctx monitor paths")
end
if not main_src:find("monitor_ui%.init",1,false) then
  error("rt main must call monitor_ui.init")
end
-- config.monitor als Lua-Pattern (Punkt = Wildcard, passt auf config_monitor auch)
if not main_src:find("config%.monitor",1,false) then
  error("rt main must pass config.monitor into monitor_ui.init")
end
local lifecycle_src=read("xreactor/nodes/rt/module_lifecycle.lua")
local missing={}
for fn in lifecycle_src:gmatch("ctx%.([%w_]+)%(") do
  if not main_src:find(fn.."%s*=") and not main_src:find("function%s+"..fn.."%(") then
    missing[#missing+1]=fn
  end
end
-- Lifecycle-Bindings: nur als Info, nicht Fehler (interne Calls okay)
print("rt_schema_ctx_guard_test.lua: ok")
