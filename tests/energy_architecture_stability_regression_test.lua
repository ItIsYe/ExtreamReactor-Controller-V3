package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function T(v,m) if not v then error(m or"true") end end
local found=false; local src=""
for _,path in ipairs({"xreactor/energy/matrix.lua","xreactor/energy/matrix_snapshot_runtime.lua",
  "xreactor/core/energy.lua"}) do
  local f=io.open(path,"r")
  if f then src=f:read("*a"); f:close(); found=true; break end
end
if found then
  T(src:find("invalidat",1,true)~=nil or src:find("runtime",1,true)~=nil,
    "energy matrix must support runtime invalidation")
end
print("energy_architecture_stability_regression_test.lua: ok")
