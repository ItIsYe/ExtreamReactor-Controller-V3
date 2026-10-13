package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
-- Ein ACK_APPLIED-Abgleich mit unveraenderten Sollwerten sendet nicht
-- erneut; ein abgelehntes Kommando wird nach SETPOINT_REJECT_RETRY_MS neu
-- gesendet (Funk-Hygiene v821; bis v820 sendete jeder Abgleich).
local constants=require('shared.constants'); local rt_sync=require('master.rt_sync')
local function T(v,m) if not v then error(m or"true",2) end end
local now=1000000; local real=os.epoch; os.epoch=function() return now end
local sends=0; local comms={send_command=function() sends=sends+1 end}
local node={id='RT-1',role=constants.roles.RT_NODE,mode='MASTER',status=constants.status_levels.OK,state=constants.node_states.RUNNING,output=2000,actual_output=2000,capacity_ready=true,capacity_max=3000}
local ctx={comms=comms,config={rt_setpoints={target_rpm=900,steam_target=4000,enable_reactors=true,enable_turbines=true}},nodes={['RT-1']=node},power_target=2000,rt_global_off=false,trigger='status',log=function() end}
rt_sync.sync_rt_node(ctx,node); T(sends==1,"erster Abgleich sendet")
now=now+800; ctx.trigger='ack_applied'
rt_sync.sync_rt_node(ctx,node); T(sends==1,"Quittung fuer dieselben Sollwerte: kein erneutes Senden")
-- Der RT lehnt ab (z. B. waehrend des Kapazitaets-Lernens).
node.last_command_result={ok=false,at=now,command_target=constants.command_targets.SET_SETPOINTS,reason_code='CAPACITY_LEARNING'}
now=now+1000
rt_sync.sync_rt_node(ctx,node); T(sends==1,"nach Ablehnung nicht sofort -- hoechstens alle "..rt_sync.SETPOINT_REJECT_RETRY_MS.." ms")
now=now+rt_sync.SETPOINT_REJECT_RETRY_MS
rt_sync.sync_rt_node(ctx,node); T(sends==2,"nach Ablehnung und Wartezeit erneut")
os.epoch=real
print("master_rt_ack_dedupe_semantic_test.lua: ok")
