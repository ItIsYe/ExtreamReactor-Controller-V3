local saved_state
local saved_path
local logs = {}

_G.os = _G.os or {}
os.epoch = function() return 1000 end
os.date = function() return '00:00:00' end

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.utils'] = {
  load_config = function(path)
    saved_path = path
    return {
      mutes = {
        rules = {
          LEGACY = { ['until'] = 2000, minutes = 5 },
          EXPIRED = { ['until'] = 500, minutes = 1 },
        },
        nodes = {
          NODE1 = { ['until'] = 3000, minutes = 10 },
          NODE2 = { until_ts = 4000, minutes = 15 },
          OLD_EXPIRED = { ['until'] = 250, minutes = 1 },
        }
      }
    }
  end,
  write_config = function(path, state)
    saved_state = { path = path, state = state }
  end,
  log = function(prefix, message, level)
    logs[#logs + 1] = { prefix = prefix, message = message, level = level }
  end,
}

package.loaded['core.alerts'] = {
  new = function()
    return {
      get_active = function() return {} end,
      get_history = function() return {} end,
      get_counts_by_severity = function() return {} end,
      render_summary = function() return '' end,
      ack = function() return false end,
      ack_all = function() return {} end,
      set_ack_for_ids = function() return {} end,
      set_ack = function() return false end,
    }
  end
}

package.loaded['core.alert_rules'] = {
  new = function()
    return { evaluate = function() return {}, {} end }
  end
}

local alert_service = require('services.alert_service')

local service = alert_service.new({ config = { alert_state_path = '/tmp/alerts_state.lua' } })
local mutes = service:get_mutes()
if mutes.rules.LEGACY == nil then
  error('legacy rule mute should remain readable')
end
if mutes.rules.EXPIRED ~= nil then
  error('expired legacy rule mute should be pruned during load')
end
if mutes.nodes.NODE1 == nil or mutes.nodes.NODE2 == nil then
  error('legacy and renamed node mutes should remain readable')
end
if mutes.nodes.OLD_EXPIRED ~= nil then
  error('expired legacy node mute should be pruned during load')
end

service:mute_rule('NEW_RULE', 7)
local new_rule = service:get_mutes().rules.NEW_RULE
if type(new_rule) ~= 'table' or type(new_rule.until_ts) ~= 'number' or new_rule['until'] ~= nil then
  error('new rule mute should persist only until_ts')
end

service:mute_node('NODE3', 9)
local new_node = service:get_mutes().nodes.NODE3
if type(new_node) ~= 'table' or type(new_node.until_ts) ~= 'number' or new_node['until'] ~= nil then
  error('new node mute should persist only until_ts')
end

if not saved_state or saved_state.path ~= '/tmp/alerts_state.lua' then
  error('mute changes should save alert state')
end
if saved_path ~= '/tmp/alerts_state.lua' then
  error('alert state path should be forwarded to load_config')
end

print('alert_service_mutes_compat_test.lua: ok')
