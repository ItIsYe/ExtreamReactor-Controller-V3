-- alert_service:tick() rief bislang self:get_counts_by_severity() auf --
-- eine Methode, die auf alert_service nie existierte (nur get_counts()
-- delegiert an core.alerts:get_counts_by_severity()). Bei aktiviertem
-- Speaker-Alarm (Standard) crashte tick() dadurch bei jedem Aufruf, sobald
-- self.speaker_alarm gesetzt war -- die komplette akustische Alarmierung
-- war unerreichbar. optional/master_ampel.lua hatte denselben Fehler in
-- seiner Guard-Klausel und zeigte dadurch nie ROT wegen kritischer Alerts.

local play_calls = {}

_G.os = _G.os or {}
os.epoch = function() return 1000 end
os.date = function() return '00:00:00' end

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.utils'] = {
  load_config = function() return { mutes = { rules = {}, nodes = {} } } end,
  write_config = function() end,
  log = function() end,
}

local counts_by_severity = { INFO = 0, WARN = 0, CRITICAL = 1 }

package.loaded['core.alerts'] = {
  new = function()
    return {
      get_active = function() return {} end,
      get_history = function() return {} end,
      get_history_filtered = function() return {} end,
      get_counts_by_severity = function() return counts_by_severity end,
      render_summary = function() return '' end,
      ack = function() return false end,
      ack_all = function() return {} end,
      set_ack_for_ids = function() return {} end,
      set_ack = function() return false end,
      raise = function() return nil end,
      resolve = function() return nil end,
      record_muted = function() end,
      tick = function() return {} end,
    }
  end
}

package.loaded['core.alert_rules'] = {
  new = function()
    return { evaluate = function() return {}, {} end }
  end
}

package.loaded['optional.speaker_alarm'] = {
  new = function()
    return {
      play = function(kind) play_calls[#play_calls + 1] = kind end,
    }
  end
}

local alert_service = require('services.alert_service')

local service = alert_service.new({ config = { alert_state_path = '/tmp/alerts_state_speaker_test.lua' } })
if not service.speaker_alarm then
  error('expected speaker_alarm to be enabled by default')
end

-- Vorher: crashte hier mit "attempt to call a nil value (method
-- 'get_counts_by_severity')", weil self:get_counts_by_severity() nicht
-- existiert. Muss jetzt sauber durchlaufen.
local ok, err = pcall(function() service:tick() end)
if not ok then
  error('alert_service:tick() must not crash with speaker_alarm enabled: ' .. tostring(err))
end

if play_calls[1] ~= 'alarm' then
  error("expected speaker_alarm to play 'alarm' for an active CRITICAL count, got: " .. tostring(play_calls[1]))
end

-- Uebergang auf keine kritischen Alerts mehr -> genau einmal 'clear' spielen.
counts_by_severity.CRITICAL = 0
service.last_eval = 0 -- Intervall-Gate umgehen, damit der zweite tick() sofort auswertet
local ok2, err2 = pcall(function() service:tick() end)
if not ok2 then
  error('alert_service:tick() must not crash on recovery: ' .. tostring(err2))
end
if play_calls[2] ~= 'clear' then
  error("expected speaker_alarm to play 'clear' on CRITICAL->none transition, got: " .. tostring(play_calls[2]))
end

-- master_ampel.lua hatte denselben Methodennamen-Fehler in seiner Guard-
-- Klausel (alert_service.get_counts_by_severity existiert nicht) und zeigte
-- dadurch nie ROT wegen kritischer Alerts, nur ueber den separaten
-- RT-SAFE/EMERGENCY-Pfad.
_G.colors = _G.colors or { green = 1, yellow = 2, orange = 4, red = 8, gray = 16 }
local master_ampel = require('optional.master_ampel')
local runtime = { refs = { alert_service = service }, state = {
  power_target = 50, active_profile = 'BASE', nodes = {},
} }
local constants = { roles = { RT_NODE = 'RT' } }
counts_by_severity.CRITICAL = 1
local color = master_ampel.determine_color(runtime, constants)
if color ~= 'red' then
  error("expected master_ampel to report 'red' for an active CRITICAL alert count, got: " .. tostring(color))
end

print('alert_service_speaker_alarm_counts_test.lua: ok')
