package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.mockup_ui'] = {
  clear=function() end, header=function() end, card=function() end,
  text=function() end,
  button=function(_mon,x,y,w,_label,_status,h)
    return {x1=x,x2=x+w-1,y=y,y2=y+h-1}
  end,
  fit=function(s,w) return tostring(s or ''):sub(1,w) end,
}
package.loaded['shared.colors'] = { get=function() return 32768 end }
package.loaded['nodes.fuel.monitor_scada'] = nil

local scale = 1.0
local writes = {}
local cursor_x, cursor_y = 1,1
local mon = {
  getTextScale=function() return scale end,
  setTextScale=function(v) scale=v end,
  getSize=function() if scale == 0.5 then return 164,81 end return 82,40 end,
  setBackgroundColor=function() end,
  getBackgroundColor=function() return 32768 end,
  setTextColor=function() end,
  getTextColor=function() return 1 end,
  setCursorPos=function(x,y) cursor_x,cursor_y=x,y end,
  getCursorPos=function() return cursor_x,cursor_y end,
  setCursorBlink=function() end,
  isColor=function() return true end,
  clear=function() writes[#writes+1]={kind='clear'} end,
  clearLine=function() end,
  scroll=function() end,
  blit=function(t,f,b)
    writes[#writes+1]={kind='blit',x=cursor_x,y=cursor_y,text=t,fg=f,bg=b}
  end,
}

local scada = require('nodes.fuel.monitor_scada')
local ok,w,h,target,s = scada.ensure(mon,0.5)
assert(ok == true and w == 164 and h == 81 and s == 0.5)
assert(target ~= mon, '0.5 must use the fullscreen scaling terminal')
local lw,lh = target.getSize()
assert(lw == 82 and lh == 40)
local binding = scada.get_binding(mon)
assert(binding.fullscreen == true)
assert(binding.origin_x == 1 and binding.origin_y == 1)
assert(binding.physical_render_width == 164 and binding.physical_render_height == 80)

-- Full-screen touch mapping: no centered dead border anymore.
local x,y,inside = scada.touch_to_local(mon,1,1)
assert(inside and x == 1 and y == 1)
x,y,inside = scada.touch_to_local(mon,2,2)
assert(inside and x == 1 and y == 1)
x,y,inside = scada.touch_to_local(mon,164,80)
assert(inside and x == 82 and y == 40)
assert(select(3,scada.touch_to_local(mon,164,81)) == false,
  'physical row 81 is not visibly owned by a logical control')

-- Native 0.5 text must stay compact, not letter-spaced across every other cell.
writes = {}
target.setCursorPos(1,1)
target.blit('ABC','000','fff')
assert(#writes == 2)
assert(writes[1].x == 1 and writes[1].y == 1)
assert(#writes[1].text == 6 and writes[1].text:sub(1,3) == 'ABC')
assert(writes[1].text ~= 'A B C ', 'text should remain native/small at scale 0.5')
assert(writes[2].y == 2 and #writes[2].text == 6)

-- Structural card borders expand to the full doubled widget width.
writes = {}
target.setCursorPos(1,2)
target.blit('+---+','00000','fffff')
assert(writes[1].text == '+--------+', writes[1].text)

ok,w,h,target,s = scada.ensure(mon,1.0)
assert(ok == true and w == 82 and h == 40 and s == 1.0)
assert(target == mon)
x,y,inside = scada.touch_to_local(mon,2,38)
assert(inside and x == 2 and y == 38)

print('fuel_ui_scale_runtime_test.lua: ok')
