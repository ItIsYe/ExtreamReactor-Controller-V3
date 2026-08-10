local f=assert(io.open('xreactor/nodes/energy/main.lua','r'));local s=f:read('*a');f:close()
for _,token in ipairs({
  'local role_logic             = require("nodes.support.role_logic")',
  'role_logic.master_peer_state(comms, constants.roles.MASTER)',
  'role_logic.is_master_connected({',
  'master_role = constants.roles.MASTER',
  'last_seen_ts = runtime.master_seen_ts',
}) do assert(s:find(token,1,true),'missing shared master-connection contract: '..token) end
assert(not s:find('local master_peer_state',1,true),'energy must not reintroduce shadowed forward-declaration master helpers')
print('energy_master_connection_scope_regression_test.lua: ok')
