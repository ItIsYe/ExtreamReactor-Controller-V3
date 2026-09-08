-- Der "profile_set"-Fernsteuerbefehl vom Pocket-Computer setzte bisher nur
-- rt_ref.state.power_target = 0 und verliess sich darauf, dass
-- runtime_ops_profile.sample_trends() den Sollwert im naechsten Zyklus neu
-- berechnet -- das passiert aber ausschliesslich im Auto-Profil-Modus
-- (runtime.state.auto_profile == true). Im manuellen Modus blieb
-- power_target dadurch dauerhaft auf 0, bis ein Bediener manuell am
-- physischen UI eingriff. Muss stattdessen denselben Pfad wie der
-- "profile"-Button im Master-UI nutzen (runtime_ops_profile.apply_profile),
-- der den Sollwert sofort und unabhaengig vom Auto-Profil-Modus neu setzt.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local apply_calls = {}
package.loaded['master.runtime_ops_profile'] = {
  apply_profile = function(runtime, name) apply_calls[#apply_calls + 1] = { runtime = runtime, name = name } end,
}

local handled_action, handled_params
package.loaded['optional.pocket_query_handler'] = {
  handle = function(message, opts)
    handled_action, handled_params = opts.execute_command("profile_set", { profile = 'peak' })
    return true
  end,
}
package.loaded['master.message_handlers'] = nil
local message_handlers = require('master.message_handlers')

local constants = require('shared.constants')
local utils = require('core.utils')
local health = require('core.health')

local handlers = message_handlers.new({
  constants = constants,
  utils = utils,
  health = health,
  nodes = {},
  comms = function() return nil end,
  sequencer = { ramp_profile = 'NORMAL' },
  mark_rt_sync_dirty = function() end,
  add_alarm = function() end,
  master_time_label = function() return 'now' end,
  log = function() end,
})

-- Manueller Modus: auto_profile ist false, wie es ein Bediener nach
-- Ausschalten des Auto-Profils erwartet.
local rt_ref = { state = { auto_profile = false, power_target = 500, active_profile = 'BASELOAD', rt_global_off_hold = false } }
message_handlers.set_runtime(rt_ref)

handlers.update_node({ type = 'POCKET', src = 'POCKET-1' })

if #apply_calls ~= 1 then
  error('expected profile_set to call runtime_ops_profile.apply_profile exactly once, got ' .. tostring(#apply_calls))
end
if apply_calls[1].runtime ~= rt_ref then
  error('apply_profile must be called with the real runtime object')
end
if apply_calls[1].name ~= 'PEAK' then
  error("expected apply_profile to be called with 'PEAK', got " .. tostring(apply_calls[1].name))
end
if handled_action ~= true then
  error('profile_set must report ok=true for a valid profile')
end

-- RT-OFF-Hold aktiv: darf apply_profile gar nicht erst aufrufen (wie
-- apply_profile es selbst auch tun wuerde), aber mit einer klaren
-- Rueckmeldung statt eines stillen no-op "Profil gesetzt".
apply_calls = {}
rt_ref.state.rt_global_off_hold = true
handled_action, handled_params = nil, nil
handlers.update_node({ type = 'POCKET', src = 'POCKET-1' })
if #apply_calls ~= 0 then
  error('apply_profile must not be called while RT-OFF-Hold is active')
end
if handled_action ~= false then
  error('profile_set must report ok=false while RT-OFF-Hold is active')
end

print('master_pocket_profile_set_manual_mode_test.lua: ok')
