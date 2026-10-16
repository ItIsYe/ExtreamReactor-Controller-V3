package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
-- Sollwerte gehen nicht bei JEDEM Abgleich raus (Funk-Hygiene v821).
--
-- Geschichte: im Mai verlangte dieser Test "keine Sende-Flut"; am 2026-06-25
-- wurde jede Dedup-Logik entfernt und der Test im August auf "jeder Abgleich
-- sendet" umgeschrieben. Der Abgleich laeuft bei jedem Heartbeat und Status
-- jedes RT -- im Anlagen-Test bekam so jeder RT alle ~1,4 s dieselben
-- Sollwerte, mit zwei Quittungen, als Rundruf an jeden Rechner. Jetzt:
-- erster Abgleich sendet, gleiche Sollwerte innerhalb der Auffrischung
-- nicht, nach SETPOINT_REFRESH_MS wieder (siehe rt_sync.setpoint_send_due).
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true",2) end end
local now=1000000; local real=os.epoch; os.epoch=function() return now end
local sends=0; local comms={send_command=function() sends=sends+1 end}
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING,output=0,actual_output=0,capacity_ready=true,capacity_max=3000}
local ctx={comms=comms,config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes={['RT-1']=node},power_target=0,rt_global_off=false,trigger='ack',log=function() end}
for _=1,3 do rt_sync.sync_rt_node(ctx,node); now=now+1500 end
T(sends==1,"drei Abgleiche mit gleichen Sollwerten innerhalb der Auffrischung: EINE Sendung, nicht drei (war "..sends..")")
now=now+rt_sync.SETPOINT_REFRESH_MS
rt_sync.sync_rt_node(ctx,node)
T(sends==2,"nach der Auffrischungszeit wird erneut gesendet")
os.epoch=real
print("rt_sync_dedupe_ack_guard_test.lua: ok")
