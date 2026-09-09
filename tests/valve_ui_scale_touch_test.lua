package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local last_button=nil
package.loaded['core.mockup_ui']={
 fit=function(s,w)return tostring(s or ''):sub(1,w)end,
 clear=function()end,header=function()end,status_dot=function()end,
 card=function()end,banner=function()end,data_row=function()end,
 button=function(_target,x,y,w,label,status,h)
  last_button={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label,status=status};return last_button
 end,
}
package.loaded['shared.colors']={get=function()return 1 end}
package.loaded['nodes.valve.local_ui']=nil
local state={current_high=false,initialized=true,last_write_error=nil,last_command_ts=1000,
 sorter_name='sorter_0',actuator_mode='sorter',redstone_side=nil,
 trusted_source='FUEL-1',pairing_persisted=true,pairing_error=nil}
local calls={}
local controller={
 get_state=function()return state end,
 apply_valve=function(_self,high,force)
  calls[#calls+1]={high=high,force=force};assert(high==true and force==true);state.current_high=true;return true
 end,
}
local target={getSize=function()return 51,19 end,setBackgroundColor=function()end,clear=function()end}
local opts={controller=controller,target=target,node_id='VALVE-1',label='VALVE-1',
 os_api={epoch=function()return 5000 end},is_master_reachable=function()return true end,
 get_comms_diagnostics=function()return{queue_depth=0}end,
 get_hop_status=function()return{configured=false,enabled=false,interval_s=4}end}
local UI=require('nodes.valve.local_ui')
opts.ui_scale=0.5
local compact=UI.new(opts)
assert(compact:render(true)==true)
assert(last_button.x1==6 and last_button.x2==45 and last_button.y==11 and last_button.y2==13)
assert(compact:get_touch_geometry().ui_scale==0.5)
assert(compact:handle_event({'mouse_click',1,25,12})==true)
assert(#calls==1 and calls[1].high==true and calls[1].force==true)
for _,p in ipairs({{5,12},{46,12},{25,10},{25,14}}) do
 assert(compact:handle_event({'mouse_click',1,p[1],p[2]})==false)
end
state.current_high=false;last_button=nil;opts.ui_scale=1.0
local normal=UI.new(opts)
assert(normal:render(true)==true)
assert(last_button.x1==2 and last_button.x2==49 and last_button.y==14 and last_button.y2==16)
assert(normal:get_touch_geometry().ui_scale==1.0)
print('valve_ui_scale_touch_test.lua: ok')
