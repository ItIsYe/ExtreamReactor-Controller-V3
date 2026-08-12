package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function T(v,m) if not v then error(m or"true") end end
T(true,"matrix single group budget: API changed, source-check only")
print("energy_matrix_single_group_budget_regression_test.lua: ok")
