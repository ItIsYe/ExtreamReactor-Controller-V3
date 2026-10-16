package.path = table.concat({ './xreactor/?.lua','./xreactor/?/init.lua',package.path }, ';')

local W,H=82,40
local function new_mon()
  local cells={}
  for y=1,H do cells[y]={}; for x=1,W do cells[y][x]=' ' end end
  local cx,cy=1,1
  return {
    getSize=function() return W,H end,
    setCursorPos=function(x,y) cx,cy=x,y end,
    setTextColor=function() end, setBackgroundColor=function() end,
    write=function(s) s=tostring(s or ''); for i=1,#s do if cx+i-1>=1 and cx+i-1<=W and cy>=1 and cy<=H then cells[cy][cx+i-1]=s:sub(i,i) end end end,
    clear=function() for y=1,H do for x=1,W do cells[y][x]=' ' end end end,
    dump=function() local o={}; for y=1,H do o[y]=table.concat(cells[y]) end; return table.concat(o,'\n') end,
  }
end
local function fit(t,w) local s=tostring(t or ''):gsub('\n',' '); w=math.max(0,w or #s); if #s<=w then return s end; if w<=2 then return s:sub(1,w) end; return s:sub(1,w-1)..'~' end
local function wr(m,x,y,s) m.setCursorPos(x,y); m.write(s) end
local mux={fit=fit}
function mux.clear(m) m.clear() end
function mux.text(m,x,y,t) wr(m,x,y,t) end
function mux.header(m,o) wr(m,1,1,string.rep('=',W)); wr(m,2,2,fit((o.title or '')..'  '..(o.node_id or ''),65)); if o.page then wr(m,76,2,fit(o.page,5)) end end
function mux.banner(m,x,y,w,t) wr(m,x,y,'['..fit(t,w-2)..string.rep(' ',math.max(0,w-2-#fit(t,w-2)))..']') end
function mux.card(m,x,y,w,h,o) wr(m,x,y,'+'..string.rep('-',w-2)..'+'); for yy=y+1,y+h-2 do wr(m,x,yy,'|'); wr(m,x+w-1,yy,'|') end; wr(m,x,y+h-1,'+'..string.rep('-',w-2)..'+'); if o and o.title then wr(m,x+2,y,fit(o.title,w-4)) end end
function mux.metric_card(m,x,y,w,h,o) mux.card(m,x,y,w,h,o); wr(m,x+2,y+1,fit(o.label or '',w-4)); wr(m,x+2,y+2,fit(o.value or '-',w-4)) end
function mux.outlined_progress(m,x,y,w,p) local inner=w-2; local n=math.floor(inner*(p or 0)+.5); wr(m,x,y,'['..string.rep('#',n)..string.rep('.',inner-n)..']') end
function mux.data_row(m,x,y,w,o) local l=tostring(o.label or ''); local r=tostring(o.value or ''); local lw=math.max(1,w-#r-1); local ls=fit(l,lw); wr(m,x,y,fit(ls..string.rep(' ',math.max(1,w-#ls-#r))..r,w)) end
function mux.section(m,x,y,w,t) wr(m,x,y,fit(t,w)); wr(m,x,y+1,string.rep('-',w)) end
function mux.warning_box(m,x,y,w,lines) mux.card(m,x,y,w,#lines+3,{title='WARNUNG'}); for i,l in ipairs(lines) do wr(m,x+2,y+1+i,fit(l,w-4)) end end
function mux.status_dot(m,x,y,l) wr(m,x,y,'* '..tostring(l)) end
function mux.table_header(m,x,y,w,cols) local p=x; for _,c in ipairs(cols) do wr(m,p,y,fit(c.label or '',c.width)); p=p+c.width end; wr(m,x,y+1,string.rep('-',w)) end
function mux.button(m,x,y,w,label,_,h) h=h or 1; local txt=fit(label,math.max(1,w-2)); for yy=y,y+h-1 do wr(m,x,yy,string.rep('#',w)) end; local ly=y+math.floor((h-1)/2); local tx=x+math.floor((w-#txt)/2); wr(m,tx,ly,txt); return{x1=x,x2=x+w-1,y=y,y2=y+h-1} end
package.loaded['core.mockup_ui']=mux
package.loaded['shared.colors']={get=function() return 1 end}
package.loaded['shared.constants']={roles={VALVE_NODE='VALVE'}}
peripheral={getNames=function() return {'minecraft:chest_1','monitor_0','wireless_modem_0'} end,getType=function(n) if n=='monitor_0' then return 'monitor' elseif n=='wireless_modem_0' then return 'modem' else return 'inventory' end end}
local function reactors(n) local o={}; for i=1,n do o[i]={reactor_id='reactor-'..i,label='Reaktor '..i,fuel_pct=(i*11)%100,fuel_data_state='FRESH',fuel_age_s=2,fuel_source='MASTER',delivery_state=i==3 and 'DELIVERING' or 'READY',operational_state='READY',route_state='ROUTE_READY',request_below=.25,fill_amount=64,min_in_me=32,resupply_cooldown_s=30,path={'VALVE-1','VALVE-2'},last_item='Uranium Block',last_element='Uranium'} end return o end
local model={node_id='FUEL-1',status='OK',master_state='OK',summary={total=9,missing=0},local_alerts={},last_scan='now',last_command='none',ui_diagnostics={error_count=0,frames_committed=2,frames_requested=3,frames_skipped=1,pointer_events_received=5,model_builds=4},view_state={code='READY',severity='OK',title='Bereit',detail='Alles bereit'},payload={reserve=18432,minimum_reserve=2000,valve_summary={total=24,offline=0,stale=0},logistics={enabled=true,bridge='meBridge_0',export_chest='chest_3',reactors=reactors(2),fuel_data_summary={fresh=2,stale=0,missing=0},fuel_families={{element='uranium',ingot_amt=64,block_amt=32,total=352}}}}}
local sc=require('nodes.fuel.scada_layout'); local ui={}; sc.attach(ui,{})
local mon=new_mon(); ui.render_overview(mon,model,true); print('===OVERVIEW==='); print(mon.dump())

local sr=require('nodes.fuel.router_scada'); local rs=reactors(8); local router={_ui={mode='list',reactors=rs,export_chest='chest_3',logistics_enabled=true,dirty=true,list_scroll=0,learn_scroll=0,chest_scroll=0,path_scroll=0,picker_scroll=0,teaching=false,save={state='IDLE'}},routing_load_status={ok=true},get_reactors=function() return {} end,redstone_router={comms={get_peers=function() return {['VALVE-1']={role='VALVE',down=false,label='Valve 1'},['VALVE-2']={role='VALVE',down=false,label='Valve 2'}} end}}}; sr.attach(router)
mon=new_mon(); router:_render_list(mon,82,40); print('===ROUTER_LIST==='); print(mon.dump())
router._ui.editing=rs[1]; mon=new_mon(); router:_render_edit(mon,82,40); print('===ROUTER_EDIT==='); print(mon.dump())
