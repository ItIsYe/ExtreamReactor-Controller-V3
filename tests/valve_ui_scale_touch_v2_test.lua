package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local last_button = nil
package.loaded['core.mockup_ui'] = {
  fit=function(s,w) return tostring(s or ''):sub(1,w) end,
  clear=function() end, header=function() end, status_dot=function() end,
  card=function() end, banner=function() end, data_row=function() end, text=function() end,
  button=function(_target,x,y,w,label,status,h)
    last_button={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label,status=status}
    return last_button
  end,
}
package.loaded['shared.colors'] = { get=function() return 1 end }
package.loaded['nodes.valve.local_ui'] = nil

local state = {
  current_high=false, initialized=true, last_write_error=nil, last_command_ts=1000,
  sorter_name='sorter_0', actuator_mode='sorter', redstone_side=nil,
  trusted_source='FUEL-1', pairing_persisted=true, pairing_error=nil,
}
local calls={}
local controller={
  get_state=function() return state end,
  apply_valve=function(_self,high,force)
    calls[#calls+1]={high=high,force=force}
    assert(high == true and force == true)
    state.current_high=true
    return true
  end,
}
local target={getSize=function() return 51,19 end,setBackgroundColor=function() end,clear=function() end}
local opts={
  controller=controller,target=target,node_id='VALVE-68',label='VALVE-68',
  os_api={epoch=function() return 5000 end},
  is_master_reachable=function() return true end,
  get_comms_diagnostics=function() return {queue_depth=0} end,
  get_hop_status=function() return {configured=false,enabled=false,interval_s=4} end,
  ui_scale=0.5,
}

local UI=require('nodes.valve.local_ui')
local compact=UI.new(opts)
assert(compact:render(true) == true)
assert(last_button.x1 == 8 and last_button.x2 == 43 and last_button.y == 11 and last_button.y2 == 13)
assert(compact:get_touch_geometry().ui_scale == 0.5)

-- Centre and all four corners of the visible rectangle are active.
local pts={{8,11},{43,11},{8,13},{43,13},{25,12}}
for _,p in ipairs(pts) do
  state.current_high=false
  assert(compact:handle_event({'mouse_click',1,p[1],p[2]}) == true)
end
assert(#calls == #pts)
for _,c in ipairs(calls) do assert(c.high == true and c.force == true) end

-- Directly adjacent cells are not invisible touch targets.
assert(compact:handle_event({'mouse_click',1,7,12}) == false)
assert(compact:handle_event({'mouse_click',1,44,12}) == false)
assert(compact:handle_event({'mouse_click',1,25,10}) == false)
assert(compact:handle_event({'mouse_click',1,25,14}) == false)
assert(compact:handle_event({'mouse_click',2,25,12}) == false)

print('valve_ui_scale_touch_v2_test.lua: ok')
