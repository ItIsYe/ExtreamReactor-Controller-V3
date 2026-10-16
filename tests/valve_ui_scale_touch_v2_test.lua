package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Beide Darstellungsgroessen der lokalen VALVE-Oberflaeche zeichnen sauber
-- und ohne jedes Bedienelement.
--
-- Diese Datei pruefte frueher die Trefferflaeche des lokalen Sperrknopfs bei
-- ui_scale 0.5. Der Knopf ist auf Betreiberwunsch entfallen (2026-09-29,
-- siehe tests/valve_local_ui_touch_test.lua) -- geblieben ist die Frage, ob
-- beide Aufbauten ueberhaupt durchlaufen und ihre Groesse korrekt melden.
-- Die kompakte Ansicht hat einen eigenen Zeichenpfad, der sonst von keinem
-- Test mehr beruehrt wuerde.

local buttons = {}
local texts = {}
package.loaded['core.mockup_ui'] = {
  fit=function(s,w) return tostring(s or ''):sub(1,w) end,
  clear=function() end, header=function() end, status_dot=function() end,
  card=function() end, banner=function() end, data_row=function() end,
  text=function(_target,x,y,t) texts[#texts+1]={x=x,y=y,text=tostring(t or '')} end,
  button=function(_target,x,y,w,label,status,h)
    buttons[#buttons+1]={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label,status=status}
    return buttons[#buttons]
  end,
}
package.loaded['shared.colors'] = { get=function() return 1 end }
package.loaded['nodes.valve.local_ui'] = nil

local state = {
  current_high=false, initialized=true, last_write_error=nil, last_command_ts=1000,
  sorter_name='sorter_0', actuator_mode='sorter', redstone_side=nil,
  trusted_source='FUEL-1', pairing_persisted=true, pairing_error=nil,
}
-- apply_valve() darf von der Oberflaeche ueberhaupt nicht mehr aufgerufen
-- werden -- deshalb kein Zaehler, sondern ein Fehler.
local controller={
  get_state=function() return state end,
  apply_valve=function()
    error('die lokale Oberflaeche darf den Aktor nicht mehr schalten', 0)
  end,
}
local target={getSize=function() return 51,19 end,setBackgroundColor=function() end,clear=function() end}
local function opts_for(scale)
  return {
    controller=controller,target=target,node_id='VALVE-68',label='VALVE-68',
    os_api={epoch=function() return 5000 end},
    is_master_reachable=function() return true end,
    get_comms_diagnostics=function() return {queue_depth=0} end,
    get_hop_status=function() return {configured=false,enabled=false,interval_s=4} end,
    ui_scale=scale,
  }
end

local UI=require('nodes.valve.local_ui')

-- Kompakter Aufbau (0.5).
local compact=UI.new(opts_for(0.5))
assert(compact:render(true) == true)
assert(compact:get_touch_geometry().ui_scale == 0.5)
assert(#buttons == 0, 'die kompakte Ansicht darf kein Bedienelement zeichnen')

local compact_valve=false
for _,t in ipairs(texts) do
  if t.y == 12 and t.text:find('VENTIL', 1, true) then compact_valve=true end
end
assert(compact_valve, 'die kompakte Ansicht zeigt den Ventilzustand auf Zeile 12')

-- Normaler Aufbau (1.0).
texts={}
local normal=UI.new(opts_for(1.0))
assert(normal:render(true) == true)
assert(normal:get_touch_geometry().ui_scale == 1.0)
assert(#buttons == 0, 'die normale Ansicht darf kein Bedienelement zeichnen')

-- Ein unbekannter Wert faellt auf 1.0 zurueck.
assert(UI.new(opts_for(0.75)):get_touch_geometry().ui_scale == 1.0)

-- Kein Klick wird in irgendeiner Groesse behandelt. Ein Treffer wuerde
-- ausserdem im controller-Stub oben mit einem Fehler auffliegen.
for _,ui in ipairs({ compact, normal }) do
  for y=1,19 do
    for _,x in ipairs({ 1, 8, 25, 43, 49, 51 }) do
      assert(ui:handle_event({'mouse_click',1,x,y}) == false,
        'Klick auf ' .. x .. '/' .. y .. ' darf nicht behandelt werden')
    end
  end
end

print('valve_ui_scale_touch_v2_test.lua: ok')
