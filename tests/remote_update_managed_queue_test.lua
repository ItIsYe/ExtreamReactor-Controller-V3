package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local original_fs = _G.fs
local original_http = _G.http
local original_handshake = _G.__xreactor_update_handshake
local original_queue_event = os.queueEvent

local arming = 'return { enabled = true, token = "secret", auto_update = true }'
_G.fs = {
  exists = function(path) return path == '/xreactor/config/remote_update.lua' end,
  open = function(path, mode)
    if path ~= '/xreactor/config/remote_update.lua' or mode ~= 'r' then return nil end
    return { readAll = function() return arming end, close = function() end }
  end,
}
_G.http = setmetatable({}, {
  __index = function(_, key) error('queue-only remote_update touched http.' .. tostring(key), 0) end,
})

local queued_events = {}
os.queueEvent = function(name) queued_events[#queued_events + 1] = name end

package.loaded['core.update_handshake'] = nil
package.loaded['core.remote_update'] = nil
local handshake_lib = require('core.update_handshake')
local remote_update = require('core.remote_update')
local handshake = handshake_lib.new()
_G.__xreactor_update_handshake = handshake

assert(remote_update.run == nil, 'remote_update must not expose a direct installer execution path')

local rejected = remote_update.queue_command({
  message = { src = 'MASTER-1', message_id = 'bad-1', command = { token = 'wrong' } },
})
assert(rejected.ok == false and rejected.reason_code == 'REMOTE_UPDATE_NOT_ARMED',
  'wrong token must be rejected before queueing')
assert(handshake.remote_update_pending == false, 'rejected update must not modify the managed queue')

local accepted = remote_update.queue_command({
  message = { src = 'MASTER-1', message_id = 'cmd-1', command = { token = 'secret' } },
})
assert(accepted.ok == true and accepted.queued == true, 'valid command must enter managed queue')
local pending = handshake_lib.peek_remote_update(handshake)
assert(pending and pending.source == 'MASTER-1' and pending.message_id == 'cmd-1'
  and pending.trigger == 'COMMAND', 'queued request metadata must preserve command identity')
assert(queued_events[1] == handshake_lib.UPDATE_EVENT, 'managed queue must wake the sole updater')

local duplicate = remote_update.queue_command({
  message = { src = 'MASTER-2', message_id = 'cmd-2', command = { token = 'secret' } },
})
assert(duplicate.ok == true, 'duplicate queue request should be idempotent')
pending = handshake_lib.peek_remote_update(handshake)
assert(pending.source == 'MASTER-1' and pending.message_id == 'cmd-1',
  'duplicate request must not overwrite the original queued identity')

local consumed = handshake_lib.consume_remote_update(handshake)
assert(consumed and handshake_lib.peek_remote_update(handshake) == nil,
  'sole updater must be able to consume and clear one request')

local local_result = remote_update.queue_local({ source = 'MASTER-LOCAL', trigger = 'REDSTONE' })
assert(local_result.ok == true, 'local physical trigger may use locally armed token implicitly')
pending = handshake_lib.peek_remote_update(handshake)
assert(pending and pending.source == 'MASTER-LOCAL' and pending.trigger == 'REDSTONE',
  'local trigger metadata must survive queueing')

local command, command_err = remote_update.build_command()
assert(command and command.target == 'REMOTE_UPDATE' and command.token == 'secret',
  'Master broadcast command must use the locally configured token: ' .. tostring(command_err))

_G.__xreactor_update_handshake = nil
local no_handshake = remote_update.queue_command({
  message = { src = 'MASTER-1', message_id = 'cmd-3', token = 'secret' },
})
assert(no_handshake.ok == false and no_handshake.reason_code == 'UPDATE_HANDSHAKE_UNAVAILABLE',
  'managed update must fail closed without the shared handshake')

_G.fs = original_fs
_G.http = original_http
_G.__xreactor_update_handshake = original_handshake
os.queueEvent = original_queue_event

print('remote_update_managed_queue_test.lua: ok')
