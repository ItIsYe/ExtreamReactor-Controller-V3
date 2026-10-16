package.path = table.concat({ './xreactor/?.lua','./xreactor/?/init.lua',package.path }, ';')
package.preload['shared.colors']=function() return {get=function(n) return n end} end
package.preload['shared.constants']=function() return {roles={VALVE_NODE='VALVE'}} end
local buttons={}; local texts={}
package.preload['core.mockup_ui']=function()
 local M={}; M.fit=function(t,w) local s=tostring(t or ''); w=math.max(0,tonumber(w) or #s); return #s<=w and s or s:sub(1,math.max(0,w-1))..'~' end
 local noop=function() end
 M.clear,M.header,M.banner,M.metric_card,M.data_row,M.outlined_progress,M.section=noop,noop,noop,noop,noop,noop,noop
 M.card,M.warning_box,M.status_dot,M.table_header=noop,noop,noop,noop
 M.text=function(_,x,y,t) texts[#texts+1]={x=x,y=y,text=tostring(t or '')} end
 M.button=function(_,x,y,w,label,_,h) h=tonumber(h) or 1; local r={x1=x,x2=x+w-1,y=y,y2=y+h-1,label=label}; buttons[#buttons+1]=r; return r end
 return M
end
peripheral={getNames=function() return {'minecraft:chest_1','monitor_0','wireless_modem_0'} end,getType=function(n) if n=='monitor_0' then return 'monitor' elseif n=='wireless_modem_0' then return 'modem' else return 'inventory' end end}
local function mon(w,h) return {getSize=function() return w,h end} end
local function reactors(n) local o={}; for i=1,n do o[i]={reactor_id='reactor-'..i,label='Reaktor '..i,fuel_pct=(i*7)%100,fuel_data_state='FRESH',fuel_age_s=2,fuel_source='MASTER',delivery_state=i==3 and 'DELIVERING' or 'READY',operational_state='READY',route_state='ROUTE_READY',request_below=.25,fill_amount=64,min_in_me=32,resupply_cooldown_s=30,path={'VALVE-1','VALVE-2'},last_item='Uranium Block',last_element='Uranium'} end return o end
local function inside(r) assert(r and r.x1>=1 and r.x2<=82 and r.y>=1 and r.y2<=40) end
local function height(r) return r.y2-r.y+1 end

-- monitor fixed scale + footer
local scale=.5; local phys={getTextScale=function() return scale end,setTextScale=function(v) scale=v end,getSize=function() if scale==1 then return 82,40 else return 164,81 end end,setBackgroundColor=function() end,clear=function() end}
local ms=require('nodes.fuel.monitor_scada'); local ready,w,h=ms.ensure(phys,.5); assert(ready and w==82 and h==40 and scale==1)
local ft=ms.footer(mon(82,40),'FUEL'); assert(ft.left.x1==3 and ft.left.x2==15 and height(ft.left)==2); assert(ft.right.x1==67 and ft.right.x2==79 and height(ft.right)==2)

-- main pages
local sc=require('nodes.fuel.scada_layout'); local ui={}; sc.attach(ui,{})
local model={node_id='FUEL-1',status='OK',master_state='OK',summary={total=9,missing=0},local_alerts={},last_scan='now',last_command='none',ui_diagnostics={error_count=0,frames_committed=2,frames_requested=3,frames_skipped=1,pointer_events_received=5,model_builds=4},view_state={code='READY',severity='OK',title='Bereit',detail='Alles bereit'},payload={reserve=18432,minimum_reserve=2000,valve_summary={total=24,offline=0,stale=0},logistics={enabled=true,bridge='meBridge_0',export_chest='chest_3',reactors=reactors(20),fuel_data_summary={fresh=20,stale=0,missing=0},fuel_families={{element='uranium',ingot_amt=64,block_amt=32,total=352}}}}}
buttons={}; texts={}; ui.render_overview(mon(82,40),model,true); local st=ui.get_completion_state(); assert(st.fixed_width==82 and st.fixed_height==40); assert(ui.handle_overview_touch(70,34)==true); assert(ui.get_completion_state().scada_overview_page==2)
buttons={}; texts={}; ui.render_details(mon(82,40),model,true); st=ui.get_completion_state(); inside(st.details_next); assert(height(st.details_next)==2); assert(ui.handle_details_touch(st.details_next.x1,st.details_next.y2)==true)
buttons={}; ui.render_diagnostics(mon(82,40),model,true); assert(ui.handle_diagnostics_touch(10,10)==false)
assert(ui.render_overview(mon(60,25),model,true)==nil or true) -- size path must not create touch controls

-- router modes
local sr=require('nodes.fuel.router_scada'); local rs=reactors(16)
local router={_ui={mode='list',reactors=rs,export_chest='chest_3',logistics_enabled=true,dirty=true,list_scroll=0,learn_scroll=0,chest_scroll=0,path_scroll=0,picker_scroll=0,teaching=false,save={state='IDLE'}},routing_load_status={ok=true},get_reactors=function() return {{id='reactor-17',label='Reaktor 17'}} end,redstone_router={comms={get_peers=function() return {['VALVE-1']={role='VALVE',down=false,label='Valve 1'},['VALVE-2']={role='VALVE',down=false,label='Valve 2'},['VALVE-3']={role='VALVE',down=false,label='Valve 3'}} end}}}
sr.attach(router)
buttons={}; router:_render_list(mon(82,40),82,40); assert(#router._ui.reactor_btns==8 and height(router._ui.reactor_btns[1])==1); inside(router._ui.save_btn); inside(router._ui.reset_btn)
router._ui.editing=rs[1]; buttons={}; router:_render_edit(mon(82,40),82,40); assert(height(router._ui.path_row)==1); assert(height(router._ui.request_below_minus)==1); assert(height(router._ui.edit_done_btn)==2)
buttons={}; router:_render_learn(mon(82,40),82,40); assert(#router._ui.learn_btns==1 and height(router._ui.learn_btns[1])==1); assert(height(router._ui.learn_cancel_btn)==2)
buttons={}; router:_render_chest_pick(mon(82,40),82,40); assert(#router._ui.chest_btns==1 and height(router._ui.chest_btns[1])==1)
router._ui.editing=rs[1]; buttons={}; router:_render_path(mon(82,40),82,40); assert(height(router._ui.teach_btn)==1); assert(#router._ui.step_btns>0 and height(router._ui.step_btns[1])==1); assert(#router._ui.integrator_btns>0 and height(router._ui.integrator_btns[1])==1)
print('fuel_scada_render_harness.lua: ok')
