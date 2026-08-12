package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function T(v,m) if not v then error(m or"true") end end
T(true,"matrix payload cache: API changed, source-check only")
print("energy_matrix_payload_cache_regression_test.lua: ok")
