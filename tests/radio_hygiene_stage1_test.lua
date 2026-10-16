package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Funk-Hygiene Stufe 1 (v821): Unnoetiges weglassen.
--
-- Befund (Anlagen-Harness, 3 RT + MASTER + FUEL + REPROCESSOR + ENERGY +
-- 4 VALVE, 60 s): 1088 Sendungen je Minute, jede als Rundruf an JEDEN
-- Rechner. Davon unnoetig:
--   * MASTER schickte jedem RT bei jedem Heartbeat/Status dieselben
--     Sollwerte (~ alle 1,4 s), je zwei Quittungen zurueck;
--   * MASTER schrieb je Abgleich ~8 INFO-Zeilen, jede per Funk an den
--     Log-Sammler (135 Log-Pakete je Minute);
--   * das Fuellstand-Relais an FUEL lief alle 4 s, quittiert, eine Quittung
--     mit der kompletten Tabelle als Echo.
-- Nach Stufe 1: 603 Sendungen je Minute.
--
--   1. Sollwerte: im ruhigen Betrieb hoechstens etwa alle 10 s je RT
--   2. Neustart eines RT (HELLO): Sollwerte sofort, nicht erst nach 10 s
--   3. Logs: DEBUG-Zeilen gehen nur mit `set xreactor.log_debug true` raus;
--      die Abgleich-Zeilen von MASTER/RT sind DEBUG
--   4. Fuellstand-Relais: alle 10 s, ohne Quittung (keine ACKs von FUEL)
--   5. Empfangsfilter fuer alle Rollen ausser MASTER
--   6. Gesamtverkehr der Anlage deutlich unter dem alten Stand

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local boot = require('support.cc_node_boot')
local constants = require('shared.constants')

local function count_sends(spec, from_index, pred)
  local n = 0
  for i = from_index + 1, #spec.env.transmitted do
    local m = spec.env.transmitted[i].message
    if pred(m, spec.env.transmitted[i]) then n = n + 1 end
  end
  return n
end

local function is_setpoint_command(m)
  return type(m) == 'table' and m.type == constants.message_types.COMMAND
    and type(m.payload) == 'table' and type(m.payload.command) == 'table'
    and m.payload.command.target == constants.command_targets.SET_SETPOINTS
end

-- ══ Anlage aufbauen ══════════════════════════════════════════════════════════
local specs = {}
for index = 1, 2 do
  specs[#specs + 1] = { name = 'RT' .. index, role = 'RT',
    env = plant.new_rt({ computer_id = 100 + index, node_id = 'rt-' .. index, turbines = 3, reactors = 1 }),
    main = 'nodes/rt/main.lua' }
end
specs[#specs + 1] = { name = 'MASTER', role = 'MASTER',
  env = plant.new_master({ computer_id = 1, node_id = 'master-1' }), main = 'master/main.lua' }
specs[#specs + 1] = { name = 'FUEL', role = 'FUEL',
  env = plant.new_fuel({ computer_id = 202, node_id = 'fuel-1', enabled = true,
    routes = [[return { export_chest = "chest_0", reactors = {} }]] }), main = 'nodes/fuel/main.lua' }
specs[#specs + 1] = { name = 'REPROC', role = 'REPROC',
  env = plant.new_reprocessor({ computer_id = 400, node_id = 'reproc-1' }), main = 'nodes/reprocessor/main.lua' }
specs[#specs + 1] = { name = 'ENERGY', role = 'ENERGY',
  env = plant.new_energy({ computer_id = 301, node_id = 'energy-1' }), main = 'nodes/energy/main.lua' }
for index = 1, 2 do
  specs[#specs + 1] = { name = 'VALVE' .. index, role = 'VALVE',
    env = plant.new_valve({ computer_id = 500 + index, node_id = 'valve-' .. index }), main = 'nodes/valve/main.lua' }
end
plant.boot_all(specs)
local net = bus_lib.new()
for _, s in ipairs(specs) do net:attach(s.name, s.env) end
local by = {}
for _, s in ipairs(specs) do by[s.name] = s end

net:run(300)   -- 30 s Anlauf: Kapazitaet, Startfolge, erste Sollwerte

local start = {}
for _, s in ipairs(specs) do start[s.name] = #s.env.transmitted end
net:run(600)   -- 60 s ruhiger Betrieb

-- ══ 1. Sollwerte im ruhigen Betrieb ═════════════════════════════════════════
do
  local per_rt = {}
  for i = start.MASTER + 1, #by.MASTER.env.transmitted do
    local m = by.MASTER.env.transmitted[i].message
    if is_setpoint_command(m) then per_rt[m.dst] = (per_rt[m.dst] or 0) + 1 end
  end
  for _, id in ipairs({ 'rt-1', 'rt-2' }) do
    local n = per_rt[id] or 0
    assert_true(n >= 5, id .. ': die Auffrischung alle 10 s muss bleiben (' .. n .. ' in 60 s)')
    assert_true(n <= 9, id .. ': hoechstens etwa alle 10 s, nicht bei jedem Heartbeat (' .. n
      .. ' in 60 s; bis v820 ~40)')
  end
end

-- ══ 3. Logs: Abgleich-Zeilen nicht mehr per Funk ════════════════════════════
local function log_lines(spec, from_index)
  local out = {}
  for i = from_index + 1, #spec.env.transmitted do
    local m = spec.env.transmitted[i].message
    if type(m) == 'table' and (m.type == 'LOG_EVENT' or m.type == 'LOG_EVENT_BATCH') then
      for _, e in ipairs(m.entries or { m }) do out[#out + 1] = tostring(e.message) end
    end
  end
  return out
end
do
  local chatter = { 'RT sync dirty queued', 'RT sync flush', 'Command queued', 'Command delivered ack',
    'Command applied ack', 'ACK_APPLIED deduped', 'RT setpoints unchanged' }
  for _, line in ipairs(log_lines(by.MASTER, start.MASTER)) do
    for _, needle in ipairs(chatter) do
      assert_true(not line:find(needle, 1, true), 'MASTER sendet keine Abgleich-Zeilen mehr per Funk: ' .. line)
    end
  end
  for _, name in ipairs({ 'RT1', 'RT2' }) do
    for _, line in ipairs(log_lines(by[name], start[name])) do
      assert_true(not line:find('command target=SET_SETPOINTS ok=true', 1, true),
        name .. ': angenommene Sollwerte sind kein Ereignis mehr: ' .. line)
    end
  end
  for _, line in ipairs(log_lines(by.FUEL, start.FUEL)) do
    assert_true(not line:find('target=FUEL_STATUS', 1, true), 'FUEL: Relais-Empfang ist Routine: ' .. line)
  end
end

-- ══ 4. Fuellstand-Relais: 10 s, ohne Quittung ══════════════════════════════
do
  local relays = count_sends(by.MASTER, start.MASTER, function(m)
    return type(m) == 'table' and m.type == constants.message_types.COMMAND
      and m.payload and m.payload.command and m.payload.command.target == constants.command_targets.FUEL_STATUS
  end)
  assert_true(relays >= 5 and relays <= 7, 'Relais alle 10 s (' .. relays .. ' in 60 s; bis v820 15)')
  local acks = count_sends(by.FUEL, start.FUEL, function(m)
    return type(m) == 'table' and (m.type == constants.message_types.ACK_DELIVERED
      or m.type == constants.message_types.ACK_APPLIED)
  end)
  assert_eq(acks, 0, 'FUEL quittiert das Relais nicht mehr')
end

-- ══ 5. Empfangsfilter: alle Rollen ausser MASTER ═══════════════════════════
do
  for _, name in ipairs({ 'RT1', 'FUEL', 'REPROC', 'ENERGY', 'VALVE1' }) do
    local env = by[name].env
    env:activate()
    local d = env.services.COMMS:get_diagnostics()
    assert_true((d.metrics.peer_only or 0) > 0, name .. ': fremde Heartbeats/Status nur als Lebenszeichen')
  end
  by.MASTER.env:activate()
  local d = by.MASTER.env.services.COMMS:get_diagnostics()
  assert_eq(d.metrics.peer_only or 0, 0, 'MASTER braucht alles -- kein Filter')
  -- Und MASTER sieht weiter alle Nodes.
  local peers = by.MASTER.env.services.COMMS:get_peers()
  for _, id in ipairs({ 'rt-1', 'rt-2', 'fuel-1', 'reproc-1', 'energy-1', 'valve-1', 'valve-2' }) do
    assert_true(peers[id] ~= nil and peers[id].down ~= true, 'MASTER hoert ' .. id)
  end
end

-- ══ 6. Gesamtverkehr ════════════════════════════════════════════════════════
do
  local total = 0
  for _, s in ipairs(specs) do total = total + (#s.env.transmitted - start[s.name]) end
  -- 9 Nodes, 60 s. Heartbeat (2 s) und Status (5 s) bleiben unveraendert:
  -- 9 * (30 + 12) = 378 je Minute ist die Untergrenze; dazu Sollwerte,
  -- Quittungen, Relais, wenige Logs. Bis v820 lag diese Anlage bei ~880.
  assert_true(total <= 560, 'Gesamtverkehr je Minute: ' .. total .. ' (bis v820 ~880)')
end

-- ══ 2. Neustart eines RT ════════════════════════════════════════════════════
do
  local old = by.RT1
  for index, entry in ipairs(net.nodes) do
    if entry.name == 'RT1' then table.remove(net.nodes, index); break end
  end
  net.by_name.RT1 = nil
  boot.reset_module_cache()
  local fresh = plant.new_rt({ computer_id = 101, node_id = 'rt-1', turbines = 3, reactors = 1 })
  fresh:activate(); fresh:boot('nodes/rt/main.lua')
  net:attach('RT1', fresh)
  -- Ablauf nach dem Neustart: HELLO -> STARTUP_STAGE -> SET_MODE; MASTER
  -- wartet, bis der RT im naechsten Status (alle 5 s) den Modus MASTER
  -- bestaetigt (rt_sync mode_sync_action), und sendet dann die Sollwerte --
  -- als "first", nicht erst mit der 10-s-Auffrischung.
  local mark = #by.MASTER.env.transmitted
  local fmark = #fresh.transmitted
  local first_at, mode_ok_at = nil, nil
  for round = 1, 120 do
    net:step()
    if not mode_ok_at then
      for i = fmark + 1, #fresh.transmitted do
        local m = fresh.transmitted[i].message
        if type(m) == 'table' and m.type == constants.message_types.STATUS
            and type(m.payload) == 'table' and m.payload.mode == 'MASTER' then
          mode_ok_at = round; break
        end
      end
      fmark = #fresh.transmitted
    end
    if not first_at then
      for i = mark + 1, #by.MASTER.env.transmitted do
        local m = by.MASTER.env.transmitted[i].message
        if is_setpoint_command(m) and m.dst == 'rt-1' then first_at = round; break end
      end
      mark = #by.MASTER.env.transmitted
    end
    if first_at then break end
  end
  assert_true(mode_ok_at ~= nil, 'der neu gestartete RT bestaetigt den Modus MASTER')
  assert_true(first_at ~= nil, 'nach dem Neustart muessen die Sollwerte kommen')
  assert_true(first_at - mode_ok_at <= 10, string.format(
    'Sollwerte sofort nach der Modus-Bestaetigung (%.1f s danach), nicht erst mit der Auffrischung',
    (first_at - mode_ok_at) / 10))
  assert_true(first_at < 100, 'deutlich vor der 10-s-Auffrischung (' .. first_at / 10 .. ' s)')
  assert_true(old ~= nil, 'alter RT war da')
end

-- ══ 3b. DEBUG-Schalter ══════════════════════════════════════════════════════
-- Dass DEBUG-Zeilen nicht per Funk gehen, belegt Abschnitt 3 an der echten
-- Anlage ("RT setpoints unchanged" ist DEBUG). Hier: die Weiche folgt der
-- Einstellung je Rechner.
do
  local utils = require('core.utils')
  local real_settings = rawget(_G, 'settings')
  local store = {}
  _G.settings = { get = function(k) return store[k] end }
  assert_eq(utils.debug_lines_enabled(), false, 'ohne Einstellung: DEBUG bleibt still')
  store['xreactor.log_debug'] = true
  assert_eq(utils.debug_lines_enabled(), true, 'set xreactor.log_debug true schaltet DEBUG ein')
  _G.settings = real_settings
end

-- ══ 2b. HELLO loescht den Sende-Zeitstempel ═════════════════════════════════
-- Fuer einen Neustart, nach dem der Plan GLEICH bleibt: ohne das Loeschen
-- kaemen die Sollwerte erst mit der Auffrischung (bis zu 10 s).
do
  local health = require('core.health')
  local rt_sync = require('master.rt_sync')
  local handlers = require('master.message_handlers')
  local same = rt_sync.normalize_setpoints({ power_target_percent = 50, assignment_state = 'active' })
  local nodes = { ['rt-9'] = { id = 'rt-9', role = constants.roles.RT_NODE, status = constants.status_levels.OK,
    health = health.new({}), last_setpoints = same, last_setpoints_ts = os.epoch('utc') } }
  local handler = handlers.new({
    constants = constants, utils = require('core.utils'), health = health, nodes = nodes,
    comms = function() return { get_peers = function() return {} end } end,
    sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end },
    sync_rt_node = function() end, mark_rt_sync_dirty = function() end, add_alarm = function() end,
    master_time_label = function() return '12:00:00' end, log = function() end,
  })
  handler.update_node({ type = constants.message_types.HELLO, sender_id = 'rt-9', src = 'rt-9', node_id = 'rt-9',
    role = constants.roles.RT_NODE, proto_ver = constants.proto_ver, payload = {} })
  assert_eq(nodes['rt-9'].last_setpoints_ts, nil, 'HELLO: Sollwerte beim naechsten Abgleich sofort senden')
  local due, why = rt_sync.setpoint_send_due(nodes['rt-9'], same, os.epoch('utc'))
  assert_true(due and why == 'first', 'gleiche Sollwerte, aber nach HELLO: senden (' .. tostring(why) .. ')')
end

-- ══ 2c. Wiederverbindung nach OFFLINE ebenso ════════════════════════════════
do
  local health = require('core.health')
  local rt_ops = require('master.runtime_ops_rt')
  local now = os.epoch('utc')
  local node = { id = 'rt-8', role = constants.roles.RT_NODE, status = constants.status_levels.OFFLINE,
    health = health.new({}), last_setpoints = {}, last_setpoints_ts = now - 1000 }
  node.health.reasons[health.reasons.COMMS_DOWN] = true
  local runtime = {
    refs = { comms = { get_peers = function() return { ['rt-8'] = { last_seen = now, down = false, age = 0 } } end } },
    config = { heartbeat_interval = 2, comms = { peer_timeout_s = 12, peer_down_grace_s = 2 } },
    state = { nodes = { ['rt-8'] = node } },
    libs = { constants = constants, health = health },
    tuning = { node_offline_purge_after_ms = 600000 },
    log = function() end,
  }
  rt_ops.check_timeouts(runtime)
  assert_eq(node.last_setpoints_ts, nil, 'wieder verbunden: Sollwerte beim naechsten Abgleich sofort senden')
end

print('ok radio_hygiene_stage1_test')
