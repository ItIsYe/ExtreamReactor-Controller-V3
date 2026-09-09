package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['shared.colors'] = {
  get = function(name)
    local map = { background=32768, text=1, muted=128, OK=32, LIMITED=2, WARNING=16, EMERGENCY=16384 }
    return map[name] or 1
  end,
}
package.loaded['nodes.fuel.half_overview'] = nil

local cursor_x, cursor_y = 1, 1
local writes = {}
local mon = {
  getSize=function() return 164,81 end,
  setCursorPos=function(x,y) cursor_x,cursor_y=x,y end,
  setTextColor=function() end,
  setBackgroundColor=function() end,
  write=function(text)
    writes[#writes+1] = {x=cursor_x,y=cursor_y,text=tostring(text)}
  end,
}

local overlay = require('nodes.fuel.half_overview')
local model = {
  payload = {
    reserve = 12340,
    minimum_reserve = 2000,
    logistics = {
      enabled = true,
      export_chest = 'minecraft:chest_0',
      reactors = {
        {label='Reaktor A', fuel_pct=61, delivery_state='READY', fuel_data_state='FRESH', fuel_age_s=2, path={'VALVE-1'}},
        {label='Reaktor B', fuel_pct=78, delivery_state='READY', fuel_data_state='FRESH', fuel_age_s=3, path={'VALVE-2','VALVE-3'}},
      },
    },
  },
  view_state = { code='READY', title='SYSTEM BEREIT', detail='Alles OK', severity='OK' },
}

assert(overlay.render(mon, model) == true)
local found_reserve, found_reactors, found_logistics = false,false,false
local found_a, found_b, found_empty, found_scada = false,false,false,false
for _,w in ipairs(writes) do
  assert(w.y >= 25 and w.y <= 72, 'overlay must stay in physical rows 25..72')
  if w.text:find('RESERVE',1,true) then found_reserve=true end
  if w.text:find('REAKTOREN',1,true) then found_reactors=true end
  if w.text:find('LOGISTIK',1,true) then found_logistics=true end
  if w.text:find('Reaktor A',1,true) then found_a=true end
  if w.text:find('Reaktor B',1,true) then found_b=true end
  if w.text:find('NICHT KONFIGURIERT',1,true) then found_empty=true end
  if w.text:find('Hinweis:',1,true) then found_scada=true end
end
assert(found_reserve and found_reactors and found_logistics and found_a and found_b and found_empty and found_scada)

-- Wrong physical size: no render and no stale writes.
writes = {}
mon.getSize=function() return 82,40 end
assert(overlay.render(mon, model) == false)
assert(#writes == 0)

print('fuel_half_overview_test.lua: ok')
