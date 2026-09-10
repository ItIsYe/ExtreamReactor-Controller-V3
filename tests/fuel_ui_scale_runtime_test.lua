package.path = table.concat({ './xreactor/?.lua','./xreactor/?/init.lua',package.path }, ';')
local buttons={}
package.loaded['core.mockup_ui']={
 clear=function() end, header=function() end, card=function() end, text=function() end,
 fit=function(t,w) return tostring(t or ''):sub(1,w) end,
 button=function(_t,x,y,w,label,status,h) local r={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label,status=status}; buttons[#buttons+1]=r; return r end,
}
package.loaded['shared.colors']={get=function() return 1 end}
package.loaded['nodes.fuel.monitor_scada']=nil
local scale=0.5
local mon={getTextScale=function() return scale end,setTextScale=function(v) scale=v end,getSize=function() if scale==1.0 then return 82,40 else return 164,81 end end,setBackgroundColor=function() end,clear=function() end}
local s=require('nodes.fuel.monitor_scada')
local ready,w,h,target,normalized=s.ensure(mon,0.5)
assert(ready and w==82 and h==40 and target==mon and normalized==1.0 and scale==1.0)
local footer=s.footer(mon,'FUEL')
assert(footer.left.x1==3 and footer.left.x2==15 and footer.left.y==38 and footer.left.y2==39)
assert(footer.right.x1==67 and footer.right.x2==79 and footer.right.y==38 and footer.right.y2==39)
print('fuel_ui_scale_runtime_test.lua: ok')
