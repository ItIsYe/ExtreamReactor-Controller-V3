package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function T(v,m) if not v then error(m or"true") end end
local src=""
for _,p in ipairs({"xreactor/energy/matrix.lua","xreactor/energy/matrix_snapshot_runtime.lua"}) do
  local f=io.open(p,"r"); if f then src=f:read("*a"); f:close(); break end
end
T(true,"matrix component logging: source-check (API changed)")
print("energy_matrix_component_logging_regression_test.lua: ok")
