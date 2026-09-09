package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local buttons = {}
package.loaded['core.mockup_ui'] = {
  clear=function() end,
  header=function() end,
  card=function() end,
  text=function() end,
  fit=function(t,w) return tostring(t or ''):sub(1,w) end,
  button=function(_t,x,y,w,label,status,h)
    local r={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label,status=status}
    buttons[#buttons+1]=r
    return r
  end,
}
package.loaded['shared.colors'] = { get=function() return 1 end }
package.loaded['nodes.fuel.monitor_scada'] = nil

local scale = 0.5
local mon = {
  getTextScale=function() return scale end,
  setTextScale=function(v) scale=v end,
  getSize=function() if scale == 1.0 then return 82,40 end return 164,81 end,
  setBackgroundColor=function() end,
  clear=function() end,
}
local scada = require('nodes.fuel.monitor_scada')
local ready,w,h,target,normalized = scada.ensure(mon,0.5)
assert(ready and w==82 and h==40 and target==mon and normalized==1.0)
assert(scale==1.0, 'FUEL must force TextScale 1.0 even when old config requests 0.5')
local x,y,inside = scada.touch_to_local(mon,82,40)
assert(inside and x==82 and y==40)
assert(select(3,scada.touch_to_local(mon,83,40)) == false)

local footer = scada.footer(mon,'FUEL')
assert(footer.left.x1==3 and footer.left.x2==17 and footer.left.y==38 and footer.left.y2==39)
assert(footer.right.x1==65 and footer.right.x2==79 and footer.right.y==38 and footer.right.y2==39)

print('fuel_ui_scale_runtime_test.lua: ok')
