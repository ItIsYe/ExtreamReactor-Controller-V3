local function install_stubs()
  _G.fs = {
    exists = function() return false end,
    open = function() return nil end,
    getDir = function() return "" end,
    makeDir = function() end,
    getSize = function() return 0 end,
    move = function() end,
    delete = function() end,
  }
  _G.textutils = {
    serialize = function(value)
      if type(value) ~= 'table' then return tostring(value) end
      local keys = {}
      for k in pairs(value) do keys[#keys+1] = tostring(k) end
      table.sort(keys)
      local out = {}
      for _, k in ipairs(keys) do out[#out+1] = k .. '=' .. tostring(value[k]) end
      return table.concat(out, ';')
    end,
    unserialize = function() return nil end,
  }
  _G.os = _G.os or {}
  local now = 0
  os.epoch = function() now = now + 100; return now end
  os.time = function() return 0 end
  os.date = function() return '00:00:00' end
  _G.settings = { get = function() return false end }
end

install_stubs()
package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local comms_lib = require('core.comms')
local energy_storage = require('adapters.energy_storage')

local sent = {}
local net = {
  id = 'NODE-1',
  role = 'TEST',
  channels = { control = 77, status = 88 },
  send = function(_, channel, payload)
    if payload.type == constants.message_types.STATUS then
      return false, 'radio-offline'
    end
    sent[#sent+1] = { channel = channel, type = payload.type, message_id = payload.message_id }
    return true
  end,
}

local comms = comms_lib.init({ network = net, node_id = 'NODE-1', role = 'TEST',
  config = { ack_timeout_s = 1, max_retries = 1, require_command_auth = false } })
comms.send(nil, constants.message_types.STATUS, { ok = true }, { require_ack = true, channel = 88 })
comms.tick()
local diag = comms.get_diagnostics()
if (diag.inflight_count or 0) ~= 0 then
  error('status messages must not enter inflight')
end
if #sent ~= 0 then
  error('failed status send must not be marked as sent')
end

comms.send('NODE-2', constants.message_types.COMMAND, { command = { value = 1 } }, { require_ack = true, channel = 77, message_id = 'cmd-1' })
comms.tick()
if #sent ~= 1 or sent[1].type ~= constants.message_types.COMMAND then
  error('command should be sent successfully')
end
local diag2 = comms.get_diagnostics()
if (diag2.inflight_count or 0) ~= 1 then
  error('command should enter inflight after successful send')
end

local methods_by_name = {
  modern = { 'getEnergy', 'getEnergyCapacity' },
  legacy = { 'getEnergyStored', 'getMaxEnergyStored' },
}
_G.peripheral = {
  isPresent = function(name) return methods_by_name[name] ~= nil end,
  getMethods = function(name) return methods_by_name[name] end,
  getType = function() return 'energy_storage' end,
  call = function(name, method)
    if name == 'modern' and method == 'getEnergy' then return 12 end
    if name == 'modern' and method == 'getEnergyCapacity' then return 34 end
    if name == 'legacy' and method == 'getEnergyStored' then return 56 end
    if name == 'legacy' and method == 'getMaxEnergyStored' then return 78 end
  end,
}
local modern = energy_storage.detect('modern', 'TEST')
if not modern or modern.getStored() ~= 12 or modern.getCapacity() ~= 34 then
  error('modern energy_storage adapter profile failed')
end
local legacy = energy_storage.detect('legacy', 'TEST')
if not legacy or legacy.getStored() ~= 56 or legacy.getCapacity() ~= 78 then
  error('legacy energy_storage adapter fallback failed')
end

print('runtime_compat_test.lua: ok')
