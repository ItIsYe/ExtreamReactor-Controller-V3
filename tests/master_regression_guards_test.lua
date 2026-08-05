package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local multiview=require('master.ui.multiview')
local function T(v,m) if not v then error(m or"true") end end
local mv=multiview.new({views={overview={render=function() end}},view_order={"overview"},on_action=function() end})
T(mv~=nil,"multiview.new returns instance"); T(type(mv.render)=="function","render exists")
T(mv.sessions~=nil,"sessions present (statt monitor_states)")
T(pcall(mv.render,mv,{},{}),"render no crash empty")
print("master_regression_guards_test.lua: ok")
