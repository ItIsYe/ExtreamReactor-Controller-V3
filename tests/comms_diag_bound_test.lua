package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local service_lib = require('services.comms_service')
local constants = require('shared.constants')

local service = service_lib.new({ log_prefix = 'MASTER', rx_diag_limit = 32 })
for i = 1, 100 do
  service:trace_master_rx({
    type = constants.message_types.STATUS,
    src = 'RT-' .. i, sender_id = 'RT-' .. i, node_id = 'RT-' .. i,
    role = constants.roles.RT_NODE,
    payload = { rt = { actual_output = i } },
  })
end

local count = 0
for _ in pairs(service.rx_diag_seen) do count = count + 1 end
assert(count <= 32, 'MASTER rx_diag_seen must remain bounded')
assert(#service.rx_diag_order <= 32, 'MASTER rx diagnostic order must remain bounded')

print('comms_diag_bound_test.lua: ok')
