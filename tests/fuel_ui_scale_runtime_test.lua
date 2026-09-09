package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.mockup_ui'] = {
  clear=function() end, header=function() end, card=function() end,
  text=function() end,
  button=function(_mon,x,y,w,_label,_status,h)
    return {x1=x,x2=x+w-1,y=y,y2=y+h-1}
  end,
  fit=function(s,w) return tostring(s or ''):sub(1,w) end,
}
package.loaded['shared.colors'] = { get=function() return 1 end }
package.loaded['nodes.fuel.monitor_scada'] = nil

local scale = 1.0
local set_calls = {}
local mon = {
  getTextScale=function() return scale end,
  setTextScale=function(v) scale=v; set_calls[#set_calls+1]=v end,
  getSize=function()
    if scale == 0.5 then return 164,81 end
    return 82,40
  end,
  setBackgroundColor=function() end,
  clear=function() end,
}

local created = nil
window = {
  create=function(parent,x,y,w,h,visible)
    assert(parent == mon)
    created={x=x,y=y,w=w,h=h,visible=visible,visible_now=visible}
    return {
      getSize=function() return w,h end,
      setVisible=function(v) created.visible_now=v end,
      setCursorPos=function() end, write=function() end,
      setBackgroundColor=function() end, setTextColor=function() end,
      clear=function() end,
    }
  end,
}

local scada = require('nodes.fuel.monitor_scada')
local ok,w,h,target,s = scada.ensure(mon,0.5)
assert(ok == true and w == 164 and h == 81 and s == 0.5)
assert(created and created.x == 42 and created.y == 21 and created.w == 82 and created.h == 40)
assert(target ~= mon)
local b = scada.get_binding(mon)
assert(b.origin_x == 42 and b.origin_y == 21)
assert(b.logical_width == 82 and b.logical_height == 40)

local x,y,inside = scada.touch_to_local(mon,42,21)
assert(inside and x == 1 and y == 1)
x,y,inside = scada.touch_to_local(mon,123,60)
assert(inside and x == 82 and y == 40)
assert(select(3,scada.touch_to_local(mon,41,21)) == false)
assert(select(3,scada.touch_to_local(mon,124,60)) == false)
assert(select(3,scada.touch_to_local(mon,42,20)) == false)
assert(select(3,scada.touch_to_local(mon,42,61)) == false)

ok,w,h,target,s = scada.ensure(mon,1.0)
assert(ok == true and w == 82 and h == 40 and s == 1.0)
assert(target == mon)
x,y,inside = scada.touch_to_local(mon,2,38)
assert(inside and x == 2 and y == 38)

print('fuel_ui_scale_runtime_test.lua: ok')
