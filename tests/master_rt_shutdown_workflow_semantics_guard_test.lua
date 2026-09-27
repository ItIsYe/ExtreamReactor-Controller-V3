package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r')); local content=f:read('*a'); f:close()
for _,stage in ipairs({'RAMPDOWN','REQUEST_STATE','REQUESTED','WAITING_STATE','COMPLETED','CANCELLED_DEMAND_RECOVERED','FAILED'}) do
  assert(content:find(stage,1,true),'missing shutdown workflow stage '..stage)
end
for _,reason in ipairs({'SUCCESS_COMPLETED','CANCELLED_DEMAND_RECOVERED','FAILED_TIMEOUT','FAILED_REJECTED','FAILED_INVALID_STATE','FAILED_ACK_MISSING'}) do
  assert(content:find(reason,1,true),'missing shutdown workflow reason '..reason)
end

-- Die zweite Haelfte dieses Tests fuhr RTs v1-Command-Handler gegen diese
-- Workflow-Stufen. Sie ist mit v769 entfallen (der v1-Handler ist entfernt);
-- was RT von diesem Ablauf annimmt, pruefen die rt2_command_handler-Tests.
-- Was hier bleibt, ist die MASTER-Seite: der Ablauf muss alle Stufen und
-- alle Abschlussgruende kennen -- genau das war der Befund, der diesen Test
-- ausgeloest hat.

print('master_rt_shutdown_workflow_semantics_guard_test.lua: ok')
