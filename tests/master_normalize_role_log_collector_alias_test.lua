-- master/message_handlers.lua's normalize_role() gibt jeder anderen Rolle
-- (RT, MASTER, ENERGY, FUEL, WATER, REPROCESSOR, VALVE) Toleranz gegenueber
-- Gross-/Kleinschreibung und Trennzeichen-Varianten (z.B. "rt"/"RTNODE"/
-- "RT-NODE" landen alle auf constants.roles.RT_NODE). LOG/LOG_COLLECTOR
-- fehlten in dieser Alias-Tabelle komplett -- eine abweichende Schreibweise
-- (z.B. "log_collector" klein, oder "LOG") wuerde unnormalisiert bleiben
-- und nicht auf constants.roles.LOG_COLLECTOR abgebildet, obwohl der
-- Log-Collector-Node selbst immer "LOG_COLLECTOR" meldet und Installer/
-- start.lua "LOG" und "LOG_COLLECTOR" bereits ueberall als gleichwertige
-- Aliase desselben Node-Typs behandeln (siehe role_descriptor/ROLE_ENTRY).

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 1000 end

local constants = require('shared.constants')
local utils = require('core.utils')
local health = require('core.health')
local message_handlers = require('master.message_handlers')

local function make_handlers(nodes)
  return message_handlers.new({
    constants = constants, utils = utils, health = health, nodes = nodes,
    comms = function() return nil end,
    sequencer = { ramp_profile = 'NORMAL' },
    mark_rt_sync_dirty = function() end,
    add_alarm = function() end,
    master_time_label = function() return 'now' end,
    log = function() end,
  })
end

local function assigned_role(role_value)
  local nodes = {}
  local handlers = make_handlers(nodes)
  handlers.update_node({
    type = constants.message_types.HELLO, sender_id = 'LOGCOL-1', node_id = 'LOGCOL-1',
    role = role_value,
  })
  local node = nodes['LOGCOL-1']
  return node and node.role or nil
end

local cases = { 'LOG_COLLECTOR', 'log_collector', 'LOG-COLLECTOR', 'LOGCOLLECTOR', 'LOG' }
for _, raw in ipairs(cases) do
  local role = assigned_role(raw)
  if role ~= constants.roles.LOG_COLLECTOR then
    error(string.format(
      "expected role %q to normalize to constants.roles.LOG_COLLECTOR (%s), got %s",
      raw, tostring(constants.roles.LOG_COLLECTOR), tostring(role)))
  end
end

print('master_normalize_role_log_collector_alias_test.lua: ok')
