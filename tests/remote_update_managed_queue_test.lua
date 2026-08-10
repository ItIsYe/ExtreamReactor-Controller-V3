package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local files = {
  ['/xreactor/config/remote_update.lua'] = 'return { enabled = true, token = "secret" }'
}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode ~= 'r' or files[path] == nil then return nil end
    return { readAll = function() return files[path] end, close = function() end }
  end,
}
_G.os = _G.os or {}
os.epoch = os.epoch or function() return 123456 end
local queued_events = {}
os.queueEvent = function(name) queued_events[#queued_events + 1] = name end
_G.http = { get = function() error('http must not be touched while merely queueing') end }

package.loaded['core.update_handshake'] = nil
package.loaded['core.remote_update'] = nil
local handshake_lib = require('core.update_handshake')
local remote_update = require('core.remote_update')
local handshake = handshake_lib.new()
_G.__xreactor_update_handshake = handshake

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end
local function assert_false(v, m) if v then error(m or 'assert_false failed') end end

local bad = remote_update.queue_command({
  message = { src = 'MASTER-1', message_id = 'm1', payload = { command = { token = 'wrong' } } }
})
assert_false(bad.ok == true, 'wrong token must be rejected before queueing')
assert_false(handshake.remote_update_pending == true, 'wrong token must not queue an update')

local good = remote_update.queue_command({
  message = { src = 'MASTER-1', message_id = 'm2', payload = { command = { token = 'secret' } } }
})
assert_true(good.ok == true and good.queued == true, 'valid armed command must queue managed update')
assert_true(handshake.remote_update_pending == true, 'handshake must record pending remote update')
assert_true(handshake.state == handshake_lib.STATE.IDLE,
  'queueing alone must not claim quiesce/runtime stopped')
assert_true(queued_events[#queued_events] == 'xreactor_remote_update_requested',
  'managed updater wake event must be emitted')

local run_ok, run_err = remote_update.run(function() end, { token = 'secret' })
assert_false(run_ok == true, 'direct installer run must be blocked while managed runtime is still active')
assert_true(tostring(run_err):find('quiesce', 1, true) ~= nil,
  'direct-run rejection must identify quiesce requirement')

_G.__xreactor_update_handshake = nil
print('remote_update_managed_queue_test.lua: ok')
