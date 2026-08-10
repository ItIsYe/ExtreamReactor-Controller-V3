from pathlib import Path
import re, zlib

ROOT = Path('.')
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def write(p,s): (ROOT/p).write_text(s,encoding='utf-8')
def replace_once(p,old,new):
    s=read(p); n=s.count(old)
    if n!=1: raise SystemExit(f'{p}: anchor count={n}: {old[:100]!r}')
    write(p,s.replace(old,new,1))
def regex_once(p,pat,repl,flags=0):
    s=read(p); out,n=re.subn(pat,lambda _m:repl,s,count=1,flags=flags)
    if n!=1: raise SystemExit(f'{p}: regex count={n}: {pat[:120]!r}')
    write(p,out)
def crc(data): return f'{zlib.crc32(data)&0xffffffff:08x}'

# ---------------------------------------------------------------------------
# RT: explicit update-safe hardware state with mandatory rod/flow readback.
# ---------------------------------------------------------------------------
reactor='xreactor/nodes/rt/reactor_control.lua'
anchor='''function M.apply_initial_reactor_rods(ctx)
'''
helper='''-- Update quiesce is stricter than normal SAFE control: every configured
-- reactor must have a successful 100%-rod write followed by a fresh readback.
-- setActive(false) is also applied/verified when that API exists. The caller
-- retries this function while the update handshake remains requested.
function M.apply_update_quiesce(ctx)
  local result = { ok = true, reactors = {} }
  for _, name in ipairs(ctx.config.reactors or {}) do
    local item = { name = name }
    local write_ok, write_err = ctx.adapters.reactor.apply_rod_level(name, 100, ctx.CONFIG.LOG_PREFIX)
    item.rod_write = write_ok == true
    item.rod_error = write_err
    local rods = ctx.adapters.reactor.read_control_rods(name, ctx.CONFIG.LOG_PREFIX)
    item.rods = rods
    item.rods_safe = type(rods) == "number" and rods >= 99.5

    local reactor = ctx.peripherals and ctx.peripherals.reactors and ctx.peripherals.reactors[name] or nil
    if not reactor and ctx.utils and type(ctx.utils.safe_wrap) == "function" then
      reactor = select(1, ctx.utils.safe_wrap(name))
    end
    item.present = reactor ~= nil
    item.active_safe = true
    if reactor and type(reactor.setActive) == "function" then
      local ok_set, set_result = pcall(reactor.setActive, false)
      item.active_write = ok_set and set_result ~= false
      if type(reactor.getActive) == "function" then
        local ok_read, active = pcall(reactor.getActive)
        item.active_readback = ok_read and type(active) == "boolean"
        item.active = active
        item.active_safe = ok_read and active == false
      else
        item.active_safe = item.active_write
      end
    elseif not reactor then
      item.active_safe = false
    end

    item.ok = item.present and item.rod_write and item.rods_safe and item.active_safe
    if item.ok then
      local ctrl = M.ensure_reactor_ctrl(ctx, name)
      ctrl.last_applied = 100
      ctrl.last_known_rods = rods
      ctrl.active_state = false
    else
      result.ok = false
    end
    result.reactors[#result.reactors + 1] = item
  end
  return result.ok, result
end

'''
replace_once(reactor,anchor,helper+anchor)

turb='xreactor/nodes/rt/turbine_control.lua'
anchor='''-- ── Overspeed-Brake-Coil ────────────────────────────────────────────────────
'''
helper='''-- Explicit update-safe turbine state: flow limit 0, inactive, and coil
-- engaged where supported. A fresh flow readback is mandatory; optional
-- active/inductor readbacks are mandatory when the corresponding getter exists.
function M.apply_update_quiesce(ctx)
  local result = { ok = true, turbines = {} }
  for _, name in ipairs(ctx.config.turbines or {}) do
    local item = { name = name }
    local turbine = ctx.peripherals and ctx.peripherals.turbines and ctx.peripherals.turbines[name] or nil
    if not turbine and ctx.utils and type(ctx.utils.safe_wrap) == "function" then
      turbine = select(1, ctx.utils.safe_wrap(name))
    end
    item.present = turbine ~= nil
    if not turbine then
      item.ok = false
      result.ok = false
      result.turbines[#result.turbines + 1] = item
      goto continue
    end

    local caps = M.get_device_caps(ctx, "turbines", name)
    local ok_flow, flow_applied = pcall(setTurbineFlow, ctx, turbine, caps, 0)
    item.flow_write = ok_flow and flow_applied == true
    local flow, flow_source = M.read_turbine_flow(ctx, turbine, caps)
    item.flow = flow
    item.flow_source = flow_source
    item.flow_safe = type(flow) == "number" and math.abs(flow) <= 0.01

    item.active_safe = true
    if type(turbine.setActive) == "function" then
      local ok_set, set_result = pcall(turbine.setActive, false)
      item.active_write = ok_set and set_result ~= false
      if type(turbine.getActive) == "function" then
        local ok_read, active = pcall(turbine.getActive)
        item.active_readback = ok_read and type(active) == "boolean"
        item.active = active
        item.active_safe = ok_read and active == false
      else
        item.active_safe = item.active_write
      end
    end

    item.inductor_safe = true
    if type(turbine.setInductorEngaged) == "function" then
      local ok_set, set_result = pcall(turbine.setInductorEngaged, true)
      item.inductor_write = ok_set and set_result ~= false
      if type(turbine.getInductorEngaged) == "function" then
        local ok_read, engaged = pcall(turbine.getInductorEngaged)
        item.inductor_readback = ok_read and type(engaged) == "boolean"
        item.inductor_engaged = engaged
        item.inductor_safe = ok_read and engaged == true
      else
        item.inductor_safe = item.inductor_write
      end
    end

    item.ok = item.flow_write and item.flow_safe and item.active_safe and item.inductor_safe
    if item.ok then
      local ctrl = get_turbine_ctrl(ctx, name)
      ctrl.flow = 0
      ctrl.requested_flow = 0
      ctrl.confirmed_flow = 0
      ctrl.active_state = false
      if item.inductor_write then ctrl.inductor_engaged = true end
    else
      result.ok = false
    end
    result.turbines[#result.turbines + 1] = item
    ::continue::
  end
  return result.ok, result
end

'''
replace_once(turb,anchor,helper+anchor)

rt='xreactor/nodes/rt/main.lua'
replace_once(rt,
'''local function control_tick()
''',
'''local rt_update_quiescing = false

local function control_tick()
  -- Once update quiesce starts, ordinary regulation/startup must never write
  -- over the dedicated safe-state commands. Network/telemetry services keep
  -- running in support_runtime until the safety readbacks are confirmed.
  if rt_update_quiescing then return end
''')
old_tail='''-- Fix (2026-07-17): CRITICAL. INSTALL-P0.2 (Abschnitt 4): expliziter
-- Quiesce-Handler. Der Audit listet RT nicht unter den Rollen mit
-- pflichtiger physischer Sicherzustandsbestaetigung (nur FUEL/
-- REPROCESSOR/VALVE/WATER) -- RT bestaetigt hier nur, dass es die
-- Hauptschleife kontrolliert verlaesst, ohne eigene neue Aktorlogik
-- einzufuehren. Getrennt davon bleibt der bestehende, MASTER-getriggerte
-- pending_remote_update-Pfad (oben) unveraendert: der blockiert die
-- Steuerschleife bereits synchron waehrend des Installerlaufs.
local quiesce_handshake = _G.__xreactor_update_handshake
support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function()
  if pending_remote_update then
    pending_remote_update = false
    log("WARN", "Remote-Update: starte Installer (deferred, Haupt-Thread)...")
    require("core.remote_update").run(log)
  end
end, quiesce_handshake and { handshake = quiesce_handshake } or nil)
'''
new_tail='''-- Update quiesce: ordinary control is frozen, every startup action is
-- cancelled, then reactor/turbine safe outputs are re-applied on every
-- handshake cycle until fresh hardware readback confirms the safe state.
local quiesce_handshake = _G.__xreactor_update_handshake
local function update_quiesce_safe()
  rt_update_quiescing = true
  active_startup_id = nil
  startup_queue_list = {}
  startup_started_ms_value = nil
  startup_watchdog_tripped_value = false
  current_state_value = STATE.SAFE
  if ctx and ctx.targets then
    ctx.targets.power = 0
    ctx.targets.power_percent = 0
    ctx.targets.steam = 0
    ctx.targets.enable_reactors = false
    ctx.targets.enable_turbines = false
  end
  for _, module in pairs(modules_registry or {}) do
    if type(module) == "table" and module.state == "STARTING" then
      module.state = "OFF"
      module.progress = 0
    end
  end

  local reactors_ok, reactor_diag = reactor_control.apply_update_quiesce(ctx)
  local turbines_ok, turbine_diag = turbine_control.apply_update_quiesce(ctx)
  if not reactors_ok or not turbines_ok then
    log("WARN", "UPDATE_QUIESCE wartet auf bestaetigte RT-Safe-Readbacks"
      .. " reactors=" .. tostring(reactors_ok) .. " turbines=" .. tostring(turbines_ok))
    return false
  end
  writeback_ctx()
  log("INFO", "UPDATE_QUIESCE SAFE_OUTPUTS_APPLIED: rods=100%, turbine_flow=0, inactive/coil readbacks bestaetigt")
  return true
end

support_runtime.run_event_loop(CONFIG.RECEIVE_TIMEOUT, services, comms, function()
  if pending_remote_update then
    pending_remote_update = false
    log("WARN", "Remote-Update: starte Installer (deferred, Haupt-Thread)...")
    require("core.remote_update").run(log)
  end
end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = update_quiesce_safe } or nil)
'''
replace_once(rt,old_tail,new_tail)

# ---------------------------------------------------------------------------
# VALVE: pair only after valid command + successful safe apply + durable save.
# ---------------------------------------------------------------------------
valve='xreactor/nodes/valve/main.lua'
replace_once(valve,
'''local seen_command_ids = {}
local seen_command_order = {}
''',
'''local seen_command_ids = {}
local seen_command_order = {}
local pairing_persisted = config.trusted_source ~= nil
local last_pairing_error = nil
''')
replace_once(valve,
'''local function send_valve_ack(reply_side, command_id, applied, high, err, dst)
''',
'''local function send_valve_ack(reply_side, command_id, applied, high, err, dst, persisted)
''')
replace_once(valve,
'''    type = "VALVE_ACK", command_id = command_id, applied = applied == true, high = high, error = err,
    src = node_id, dst = dst,
''',
'''    type = "VALVE_ACK", command_id = command_id, applied = applied == true, high = high, error = err,
    src = node_id, dst = dst, persisted = persisted,
''')
# Replace trust+apply segment in one guarded block.
pat=r'''  if config\.trusted_source then\n    if message\.src ~= config\.trusted_source then.*?  send_valve_ack\(reply_side, message\.command_id, applied, current_high, last_write_error, message\.src\)'''
repl='''  if config.trusted_source and message.src ~= config.trusted_source then
    utils.log(CONFIG.LOG_PREFIX, "SET_VALVE von nicht vertrauenswuerdiger Quelle ignoriert: " .. tostring(message.src), "WARN")
    return
  end

  -- Dedupe is safe only for an already paired source. An unpaired command has
  -- to pass the physical apply and durable trust write before its ID is saved.
  if config.trusted_source and seen_command(message.command_id) then
    local applied = valve_initialized and (current_high == message.high)
    send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error,
      message.src, pairing_persisted)
    return
  end

  local applied = apply_valve(message.high)
  if not applied then
    send_valve_ack(reply_side, message.command_id, false, current_high, last_write_error,
      message.src, config.trusted_source ~= nil and pairing_persisted or false)
    return
  end

  if not config.trusted_source then
    -- Pair only AFTER the fully validated command was physically applied.
    -- If persistence fails, fail closed again before answering: a transient,
    -- unauthenticated first packet must never leave the sorter open.
    config.trusted_source = message.src
    local ok_pair, perr = utils.write_config(CONFIG.CONFIG_PATH, config)
    if not ok_pair then
      config.trusted_source = nil
      pairing_persisted = false
      last_pairing_error = tostring(perr or "write_config failed")
      local blocked_ok = apply_valve(true)
      utils.log(CONFIG.LOG_PREFIX, "trusted_source-Pairing NICHT dauerhaft gespeichert ("
        .. last_pairing_error .. ") -- Fail-Safe BLOCKED=" .. tostring(blocked_ok), "ERROR")
      send_valve_ack(reply_side, message.command_id, false, current_high,
        "PAIRING_PERSIST_FAILED:" .. last_pairing_error, message.src, false)
      return
    end
    pairing_persisted = true
    last_pairing_error = nil
    utils.log(CONFIG.LOG_PREFIX, "trusted_source nach erfolgreichem Apply dauerhaft an "
      .. tostring(message.src) .. " gebunden", "INFO")
  end

  remember_command(message.command_id)
  send_valve_ack(reply_side, message.command_id, true, current_high, nil, message.src, pairing_persisted)'''
regex_once(valve,pat,repl,re.S)
replace_once(valve,
'''      actuator_name = sorter_resolved_name or config.sorter_name,
''',
'''      actuator_name = sorter_resolved_name or config.sorter_name,
      trusted_source = config.trusted_source,
      pairing_persisted = pairing_persisted,
      pairing_error = last_pairing_error,
''')

# ---------------------------------------------------------------------------
# FUEL persistent SET_RESERVE + MASTER persistent ACK semantics.
# ---------------------------------------------------------------------------
fuel_cmd='xreactor/nodes/fuel/command_handler.lua'
replace_once(fuel_cmd,
'''      ctx.set_reserve(new_reserve)
      ctx.utils.log("FUEL", "Reserve updated to " .. tostring(new_reserve))
''',
'''      local result = ctx.set_reserve(new_reserve)
      ctx.utils.log("FUEL", "Reserve updated to " .. tostring(new_reserve)
        .. " persisted=" .. tostring(type(result) == "table" and result.persisted == true))
      if type(result) == "table" then
        return sch.finish_with_result(devices, result)
      end
''')

fuel_main='xreactor/nodes/fuel/main.lua'
replace_once(fuel_main,
'''    set_reserve = function(v) reserve = v end,
''',
'''    set_reserve = function(v)
      reserve = v
      config.minimum_reserve = v
      local ok_write, werr = utils.write_config(CONFIG.CONFIG_PATH, config)
      if not ok_write then
        utils.log("FUEL", "SET_RESERVE angewendet, aber Persistierung fehlgeschlagen: " .. tostring(werr), "WARN")
      end
      return { ok = true, persisted = ok_write == true, persistence_error = ok_write and nil or tostring(werr) }
    end,
''')

master='xreactor/master/config_edits.lua'
replace_once(master,
'''  fuel_reserve = { role_key = "FUEL_NODE", command_target = "SET_RESERVE" },
  water_target = { role_key = "WATER_NODE", command_target = "SET_TARGET" },
  reactor_fill_target = { role_key = "RT_NODE", command_target = "SET_REACTOR_FILL_TARGET" },
''',
'''  fuel_reserve = { role_key = "FUEL_NODE", command_target = "SET_RESERVE", requires_persistence = true },
  water_target = { role_key = "WATER_NODE", command_target = "SET_TARGET", requires_persistence = true },
  reactor_fill_target = { role_key = "RT_NODE", command_target = "SET_REACTOR_FILL_TARGET", requires_persistence = true },
''')
replace_once(master,
'''local function all_applied(pending)
  for _, t in pairs(pending.targets) do
    if t.status ~= "APPLIED" then return false end
  end
  return true
end
''',
'''local function all_persisted(pending)
  for _, t in pairs(pending.targets) do
    if t.status ~= "APPLIED_PERSISTED" then return false end
  end
  return true
end
''')
replace_once(master,
'''  if all_applied(st.pending) then
''',
'''  if all_persisted(st.pending) then
''')
replace_once(master,
'''function M.handle_ack_applied(edits_state, message)
  local _, st, _, t = find_pending(edits_state, message and message.ack_for)
  if not t then return false end
  local result = message.payload and message.payload.result or {}
  if result.ok == false then
    t.status = "REJECTED"
    t.error = result.error or result.reason_code
  else
    t.status = "APPLIED"
  end
  resolve_if_terminal(st)
  return true
end
''',
'''function M.handle_ack_applied(edits_state, message)
  local key, st, _, t = find_pending(edits_state, message and message.ack_for)
  if not t then return false end
  local result = message.payload and message.payload.result or {}
  local def = key and M.SETTINGS[key] or nil
  if result.ok == false then
    t.status = "REJECTED"
    t.error = result.error or result.reason_code
  elseif def and def.requires_persistence then
    if result.persisted == true then
      t.status = "APPLIED_PERSISTED"
    else
      t.status = "APPLIED_VOLATILE"
      t.error = result.persistence_error or result.error or "Wert nur im RAM angewendet; Persistierung nicht bestaetigt"
    end
  else
    t.status = "APPLIED_PERSISTED"
  end
  resolve_if_terminal(st)
  return true
end
''')
replace_once(master,
'''    local applied, total, failed_ids = 0, 0, {}
''',
'''    local applied, total, failed_ids, volatile_ids = 0, 0, {}, {}
''')
replace_once(master,
'''      if t.status == "APPLIED" then
        applied = applied + 1
      elseif t.status == "REJECTED" or t.status == "TIMEOUT" or t.status == "SEND_FAILED" then
        failed_ids[#failed_ids + 1] = id
      end
''',
'''      if t.status == "APPLIED_PERSISTED" then
        applied = applied + 1
      elseif t.status == "APPLIED_VOLATILE" then
        volatile_ids[#volatile_ids + 1] = id
      elseif t.status == "REJECTED" or t.status == "TIMEOUT" or t.status == "SEND_FAILED" then
        failed_ids[#failed_ids + 1] = id
      end
''')
replace_once(master,
'''      failed = failed_ids, resolved = st.pending.resolved == true,
''',
'''      failed = failed_ids, volatile = volatile_ids, resolved = st.pending.resolved == true,
''')

# Existing config-edit regression now requires durable ACKs and explicitly
# covers volatile application without promoting confirmed_value.
test='tests/master_config_edits_test.lua'
s=read(test)
s=s.replace("payload = { result = { ok = true } }", "payload = { result = { ok = true, persisted = true } }")
# all 3 occurrences should be converted (two scenario 6, one scenario 7)
if 'result = { ok = true }' in s: raise SystemExit('master config test still contains persistence-ambiguous success')
insert='''
-- 9. Persistent setting applied only in RAM is terminal but NOT confirmed.
do
  local nodes = { ['FUEL-1'] = { role = constants.roles.FUEL_NODE } }
  local comms = make_comms()
  local edits_state = {}
  config_edits.send_edit(edits_state, 'fuel_reserve', 3500, { nodes = nodes, comms = comms, constants = constants })
  local id1 = comms.sent[1].message_id
  config_edits.handle_ack_applied(edits_state, { ack_for = id1,
    payload = { result = { ok = true, persisted = false, persistence_error = 'disk full' } } })
  local model = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model.confirmed_value, 2000, 'volatile-only application must never become the persisted confirmed value')
  assert_true(model.pending and model.pending.resolved == true, 'volatile result is terminal and must remain visible')
  assert_eq(#model.pending.volatile, 1, 'volatile target must be surfaced separately from reject/timeout')
  assert_eq(edits_state.fuel_reserve.pending.targets['FUEL-1'].status, 'APPLIED_VOLATILE')
end

'''
s=s.replace("print('master_config_edits_test.lua: ok')",insert+"print('master_config_edits_test.lua: ok')")
write(test,s)

# Dedicated FUEL persistence ACK test.
write('tests/fuel_reserve_persistence_ack_test.lua','''package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local handler=require('nodes.fuel.command_handler')
local devices={}
local result
local sch={
  parse_node_command=function() return {target='SET_RESERVE',value=4200} end,
  finish_with_result=function(_,r) result=r; return r end,
  finish=function() return {ok=true} end,
  reject_unsupported=function() return {ok=false} end,
}
local calls=0
local out=handler.handle({}, {support_command_handler=sch,constants={command_targets={SET_RESERVE='SET_RESERVE',FUEL_STATUS='FUEL_STATUS',MODE='MODE'},node_states={MANUAL='MANUAL'}},devices=devices,
  protocol={},comms={},utils={log=function() end},set_reserve=function(v) calls=calls+1; assert(v==4200); return {ok=true,persisted=false,persistence_error='disk full'} end,on_fuel_status=function() end})
assert(calls==1 and out.persisted==false and out.persistence_error=='disk full','SET_RESERVE ACK must preserve persistence failure')
print('fuel_reserve_persistence_ack_test.lua: ok')
''')

# Dedicated VALVE source-contract test: pairing assignment must occur after
# apply_valve and persistence failure must force fail-safe blocked before ACK.
write('tests/valve_pair_after_apply_persistence_guard_test.lua','''local function read(p) local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local root=os.getenv('REPO_ROOT') or '.'
local s=read(root..'/xreactor/nodes/valve/main.lua')
local validate=s:find('if type(message.high) ~= "boolean" then',1,true)
local apply=s:find('local applied = apply_valve(message.high)',validate or 1,true)
local pair=s:find('config.trusted_source = message.src',apply or 1,true)
local persist=s:find('utils.write_config(CONFIG.CONFIG_PATH, config)',pair or 1,true)
assert(validate and apply and pair and persist and validate < apply and apply < pair and pair < persist,
  'VALVE pairing must happen only after full validation and successful physical apply')
assert(s:find('config.trusted_source = nil',persist,true),'pair persistence failure must undo RAM trust')
assert(s:find('local blocked_ok = apply_valve(true)',persist,true),'pair persistence failure must fail closed physically')
assert(s:find('PAIRING_PERSIST_FAILED',persist,true),'ACK must surface pairing persistence failure')
print('valve_pair_after_apply_persistence_guard_test.lua: ok')
''')

# Behavioral RT update-safe functions with write/readback failures.
write('tests/rt_update_quiesce_hardware_confirmation_test.lua','''package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local rc=require('nodes.rt.reactor_control')
local tc=require('nodes.rt.turbine_control')
_G.peripheral={getMethods=function() return {'setFluidFlowRateMax','getFluidFlowRateMax','setActive','getActive','setInductorEngaged','getInductorEngaged'} end}
local rod_read=100
local reactor={active=true,setActive=function(v) reactor.active=v end,getActive=function() return reactor.active end}
local rctx={config={reactors={'R1'}},CONFIG={LOG_PREFIX='RT'},peripherals={reactors={R1=reactor}},utils={safe_wrap=function() return reactor end},reactor_ctrl={},
  adapters={reactor={apply_rod_level=function(_,v) return v==100 end,read_control_rods=function() return rod_read end}}}
local ok=rc.apply_update_quiesce(rctx)
assert(ok==true and reactor.active==false,'reactor quiesce needs rods=100 readback and inactive confirmation')
rod_read=90
assert(rc.apply_update_quiesce(rctx)==false,'unsafe rod readback must keep RT quiesce pending')

local flow=0; local active=true; local coil=false
local turbine={setFluidFlowRateMax=function(v) flow=v end,getFluidFlowRateMax=function() return flow end,setActive=function(v) active=v end,getActive=function() return active end,
  setInductorEngaged=function(v) coil=v end,getInductorEngaged=function() return coil end}
local tctx={config={turbines={'T1'}},CONFIG={START_FLOW=100,TURBINE_MODE_RAMP='RAMP'},peripherals={turbines={T1=turbine}},utils={safe_wrap=function() return turbine end},
  capability_cache={turbines={}},turbine_ctrl_store={},autonom_state={turbines={}},binding={missing_devices_message=function() return '' end,build_policy=function() return {} end},
  runtime_config={configured_reactors={},configured_turbines={}},flow_apply_helpers={reset_log_state=function() end},log=function() end,safe_wrapped_call=function(obj,m,...) return pcall(obj[m],...) end,
  safety={clamp=function(v,a,b) return math.max(a,math.min(b,v)) end},CONFIG={START_FLOW=100,TURBINE_MODE_RAMP='RAMP',MIN_FLOW=0,MAX_FLOW=2000}}
local tok=tc.apply_update_quiesce(tctx)
assert(tok==true and flow==0 and active==false and coil==true,'turbine quiesce must confirm zero flow/inactive/coil')
turbine.getFluidFlowRateMax=function() return 50 end
assert(tc.apply_update_quiesce(tctx)==false,'nonzero flow readback must keep RT quiesce pending')
print('rt_update_quiesce_hardware_confirmation_test.lua: ok')
''')

# Update structural quiesce test: RT is no longer a trivial handler.
wiring='tests/install_p0_2_quiesce_wiring_test.lua'
replace_once(wiring,
'''-- ── RT: trivialer Handler (Audit verlangt hier keine physische Bestaetigung) ─
do
  local src = read("nodes/rt/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "rt/main.lua")
  assert_contains(src, "quiesce_handshake and { handshake = quiesce_handshake } or nil", "rt/main.lua")
end
''',
'''-- ── RT: Control freeze + physische Safe-Readback-Bestaetigung ─────────────
do
  local src = read("nodes/rt/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "rt/main.lua")
  assert_contains(src, "if rt_update_quiescing then return end", "rt/main.lua")
  assert_contains(src, "reactor_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "turbine_control.apply_update_quiesce(ctx)", "rt/main.lua")
  assert_contains(src, "on_quiesce = update_quiesce_safe", "rt/main.lua")
end
''')

# Release v517, preserving manifest semantics and updating only changed runtime files.
release=read('xreactor/release.lua')
for old,new in [('beta-v516','beta-v517'),('manifest-v516','manifest-v517'),('manifest_version = 516','manifest_version = 517')]:
    if release.count(old)!=1: raise SystemExit('release anchor '+old)
    release=release.replace(old,new,1)
write('xreactor/release.lua',release)
manifest=read('xreactor/manifest.lua')
manifest=manifest.replace('-- xreactor/manifest.lua -- manifest-v516','-- xreactor/manifest.lua -- manifest-v517',1)
manifest=manifest.replace('manifest_version = 516','manifest_version = 517',1)
manifest=manifest.replace('manifest_id = "manifest-v516"','manifest_id = "manifest-v517"',1)
changed=['nodes/rt/reactor_control.lua','nodes/rt/turbine_control.lua','nodes/rt/main.lua','nodes/valve/main.lua','master/config_edits.lua','nodes/fuel/command_handler.lua','nodes/fuel/main.lua','release.lua']
for rel in changed:
    data=(ROOT/'xreactor'/rel).read_bytes(); lines=manifest.splitlines(True); idx=[i for i,l in enumerate(lines) if f'path = "{rel}"' in l]
    if len(idx)!=1: raise SystemExit(f'manifest entry {rel} count={len(idx)}')
    i=idx[0]; line=lines[i]
    line,n1=re.subn(r'size_bytes\s*=\s*\d+',f'size_bytes = {len(data)}',line,count=1)
    line,n2=re.subn(r'hash\s*=\s*"[0-9a-f]+"',f'hash = "{crc(data)}"',line,count=1)
    if n1!=1 or n2!=1: raise SystemExit('manifest shape '+rel)
    lines[i]=line; manifest=''.join(lines)
write('xreactor/manifest.lua',manifest)
print('phase5 patch applied')
