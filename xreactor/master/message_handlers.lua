local M = {}
local rt_sync = require("master.rt_sync")
local support_status = require("master.support_status")
local config_edits_lib = require("master.config_edits")
local profile_ops = require("master.runtime_ops_profile")

function M.new(opts)
  local constants = assert(opts.constants, "constants required")
  local utils = assert(opts.utils, "utils required")
  local health = assert(opts.health, "health required")
  local nodes = assert(opts.nodes, "nodes required")
  local comms = assert(opts.comms, "comms getter required")
  local sequencer = assert(opts.sequencer, "sequencer required")
  local mark_rt_sync_dirty = assert(opts.mark_rt_sync_dirty, "mark_rt_sync_dirty required")
  local add_alarm = assert(opts.add_alarm, "add_alarm required")
  local master_time_label = assert(opts.master_time_label, "master_time_label required")
  local log = assert(opts.log, "log required")
  -- Optional -- nur vom echten Master-Boot (runtime_loop.lua) gesetzt,
  -- damit Tests, die M.new() ohne Config-Editor-Belange aufrufen,
  -- unveraendert funktionieren.
  local config_edits_state = opts.config_edits_state
  local on_config_edit_change = opts.on_config_edit_change


  local function format_reasons(reason_set)
    if type(reason_set) ~= "table" then return "none" end
    local out = {}
    for reason, enabled in pairs(reason_set) do
      if enabled then out[#out + 1] = tostring(reason) end
    end
    table.sort(out)
    return #out > 0 and table.concat(out, ",") or "none"
  end

  local function reasons_to_set(reasons)
    if type(reasons) ~= "table" then return {} end
    local out = {}
    local is_array = (#reasons > 0)
    if is_array then
      for _, reason in ipairs(reasons) do out[tostring(reason)] = true end
      return out
    end
    for reason, enabled in pairs(reasons) do
      if enabled then out[tostring(reason)] = true end
    end
    return out
  end

  -- Fix P4: number_or_nil aus utils, mit Fallback für ältere utils-Versionen
  local number_or_nil = utils.number_or_nil or function(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then local n = tonumber(v); if n then return n end end
    return nil
  end

  local function sum_turbine_output(turbines)
    if type(turbines) ~= "table" then return nil end
    local total = 0
    local count = 0
    for _, turbine in pairs(turbines) do
      if type(turbine) == "table" then
        local value = number_or_nil(turbine.energy or turbine.output or turbine.power_actual or turbine.actual_output)
        if value then
          total = total + value
          count = count + 1
        end
      end
    end
    if count > 0 then return total end
    return nil
  end

  local function normalize_role(raw)
    if raw == nil then return nil end
    local value = tostring(raw):upper():gsub("_", "-")
    if value == "RT" or value == "RTNODE" or value == "RT-NODE" or value == "REACTOR-TURBINE" then return constants.roles.RT_NODE end
    if value == "MASTER" then return constants.roles.MASTER end
    if value == "ENERGY" or value == "ENERGY-NODE" or value == "ENERGYNODE" then return constants.roles.ENERGY_NODE end
    if value == "FUEL" or value == "FUEL-NODE" or value == "FUELNODE" then return constants.roles.FUEL_NODE end
    if value == "WATER" or value == "WATER-NODE" or value == "WATERNODE" then return constants.roles.WATER_NODE end
    if value == "REPROCESSING" or value == "REPROCESSOR" or value == "REPROCESSOR-NODE" or value == "REPROCESSING-NODE" then return constants.roles.REPROCESSOR_NODE end
    if value == "VALVE" or value == "FUEL-VALVE" or value == "VALVE-NODE" or value == "FUELVALVE" then return constants.roles.VALVE_NODE end
    -- LOG und LOG_COLLECTOR sind ueberall sonst (role_descriptor/start.lua's
    -- ROLE_ENTRY) bereits gleichwertige Aliase desselben Node-Typs -- ohne
    -- diesen Zweig fehlte hier als einziger Rolle die sonst ueberall
    -- vorhandene Gross-/Trennzeichen-Toleranz.
    if value == "LOG" or value == "LOG-COLLECTOR" or value == "LOGCOLLECTOR" then return constants.roles.LOG_COLLECTOR end
    return raw
  end

  -- Fix P3: payload_looks_rt jetzt in utils zentralisiert
  local payload_looks_rt = utils.payload_looks_rt

  local function infer_message_role(message)
    local payload = message and message.payload or nil
    local role = normalize_role(message and message.role)
    if role ~= nil then return role end
    role = normalize_role(type(payload) == "table" and payload.role or nil)
    if role ~= nil then return role end
    role = normalize_role(type(payload) == "table" and type(payload.meta) == "table" and payload.meta.role or nil)
    if role ~= nil then return role end
    if payload_looks_rt(payload) then return constants.roles.RT_NODE end
    return nil
  end

  local function apply_role_hint(node, role_hint, origin)
    if type(node) ~= "table" or role_hint == nil then return end
    local normalized = normalize_role(role_hint)
    if normalized == nil then return end
    local previous = node.role
    if previous ~= normalized then
      node.role = normalized
      log(("Node %s role %s -> %s (%s)"):format(tostring(node.id or "?"), tostring(previous or "UNKNOWN"), tostring(normalized), tostring(origin or "role_hint")), "INFO")
    end
  end

  local function assign_node_status_from_health(node, origin)
    local previous_status = node.status
    local health_payload = node.health
    local computed = previous_status
    if health_payload and health_payload.status then
      computed = health_payload.status
    end
    local reasons = reasons_to_set(health_payload and health_payload.reasons)
    local shutdown_state = node.last_setpoints and node.last_setpoints.assignment_state
    local workflow_stage = node.shutdown_workflow and node.shutdown_workflow.stage or nil
    local controlled_shutdown = shutdown_state == "shutdown" or shutdown_state == "shed" or shutdown_state == "standby" or
        workflow_stage == "RAMPDOWN" or workflow_stage == "REQUEST_STATE" or workflow_stage == "REQUESTED" or workflow_stage == "WAITING_STATE"
    if controlled_shutdown and computed == health.status.DEGRADED then
      if reasons[health.reasons.COMMS_DOWN] ~= true and reasons[health.reasons.PROTO_MISMATCH] ~= true and reasons[health.reasons.DISCOVERY_FAILED] ~= true then
        computed = constants.status_levels.OK
        log(("Node %s suppresses degraded during controlled shutdown: state=%s assign=%s reasons=%s source=%s"):format(
          tostring(node.id), tostring(node.state), tostring(shutdown_state), format_reasons(reasons), tostring(origin or "unknown")
        ))
      end
    end
    node.status = computed or constants.status_levels.OK
    if previous_status ~= node.status then
      log(("Node %s status %s -> %s (%s)"):format(tostring(node.id), tostring(previous_status or "UNKNOWN"), tostring(node.status), tostring(origin or "unknown")))
    end
  end

  local function ack_matches_last_setpoints(node, result)
    if type(result) ~= "table" or result.ok == false then return false end
    local target = result.command_target
    local expected_target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET
    if target ~= expected_target then return false end
    local value = result.command_value
    local last = node and node.last_setpoints
    if type(value) ~= "table" or type(last) ~= "table" then return false end
    return rt_sync.same_setpoints(rt_sync.normalize_setpoints(value), rt_sync.normalize_setpoints(last))
  end

  -- Fix P2: populate_rt_status bereinigt.
  -- Kanonische Felder: rt.actual_output, rt.power_target, node.actual_output, node.power_target.
  -- Aliase (output, power_actual, target_output) werden einmalig am Ende gesetzt.
  local function populate_rt_status(node, payload)
    if type(node) ~= "table" or type(payload) ~= "table" then return end
    -- Bestehende node.rt-Tabelle wiederverwenden und payload.rt-Felder
    -- hineinmergen (nicht die Referenz ersetzen) -- sonst gingen Felder
    -- verloren, die nicht von RT selbst gesendet, sondern vom Master/UI-
    -- Controller in node.rt geschrieben werden (z.B. assignment_state).
    if type(node.rt) ~= "table" then node.rt = {} end
    if type(payload.rt) == "table" then
      for k, v in pairs(payload.rt) do
        node.rt[k] = v
      end
    end
    local rt = node.rt

    -- Kanonische Werte berechnen
    local actual_output = number_or_nil(payload.actual_output or payload.power_actual)
      or sum_turbine_output(payload.turbines)
      or number_or_nil(rt.actual_output)
    local power_target = number_or_nil(payload.power_target or payload.target_output or payload.output)

    -- rt-Felder: Identität und Modus
    rt.id = rt.id or node.id or payload.id or payload.node_id
    rt.status = payload.status or rt.status or node.status
    rt.state = payload.state or rt.state or node.state
    rt.mode = payload.mode or rt.mode or node.mode
    rt.control_mode = payload.control_mode or rt.control_mode or payload.mode
    -- Fix I3: assignment_state kommt immer vom letzten Payload,
    -- nicht sticky aus vorherigem Zustand (sonst veraltet er)
    rt.assignment_state = payload.assignment_state or rt.assignment_state
    rt.assignment_reason = rt.assignment_reason or payload.assignment_reason or payload.bindings_summary
    rt.control_source = rt.control_source or payload.control_source

    -- rt-Felder: Leistung (kanonisch)
    rt.actual_output = actual_output or rt.actual_output or 0
    rt.power_target = power_target or rt.power_target

    -- rt-Felder: Hardware-Daten
    rt.turbine_rpm = payload.turbine_rpm or rt.turbine_rpm
    rt.steam = payload.steam or rt.steam
    rt.capabilities = payload.capabilities or rt.capabilities
    rt.bindings = payload.bindings or rt.bindings
    rt.bindings_summary = payload.bindings_summary or rt.bindings_summary
    rt.modules = payload.modules or rt.modules
    rt.turbines = payload.turbines or rt.turbines
    rt.reactors = payload.reactors or rt.reactors
    rt.registry = payload.registry or rt.registry
    rt.snapshot = payload.snapshot or rt.snapshot
    rt.ramp_state = payload.ramp_state or rt.ramp_state
    if type(payload.turbines) == "table" then rt.turbine_count = #payload.turbines end
    if type(payload.reactors) == "table" then rt.reactor_count = #payload.reactors end

    -- Modul-Zähler
    if type(payload.modules) == "table" then
      local total, running, stable, limited, error_count = 0, 0, 0, 0, 0
      for _, module in pairs(payload.modules) do
        total = total + 1
        local state = tostring(type(module) == "table" and module.state or ""):upper()
        if state == "RUNNING" then running = running + 1 end
        if state == "STABLE" then stable = stable + 1 end
        if state == "LIMITED" then limited = limited + 1 end
        if state == "ERROR" or state == "FAILED" then error_count = error_count + 1 end
      end
      rt.module_count = total
      rt.modules_running = running
      rt.modules_stable = stable
      rt.modules_limited = limited
      rt.modules_error = error_count
    end

    -- node-Felder: kanonisch + Aliase einmalig
    node.actual_output  = rt.actual_output
    node.power_target   = rt.power_target
    -- Muss VOR der node.capacity_max/node.capacity_ready-Ableitung unten
    -- aktualisiert werden -- sonst spiegeln die node.*-Werte den vorherigen
    -- STATUS-Zyklus statt des gerade eingetroffenen wider (off-by-one),
    -- und rt_sync.node_capacity() teilt falsche Setpoints zu.
    rt.capacity_max     = number_or_nil(payload.capacity_max) or rt.capacity_max
    if payload.capacity_ready == true then rt.capacity_ready = true end
    rt.capacity_source  = payload.capacity_source or rt.capacity_source
    rt.capacity_stable_turbines  = number_or_nil(payload.capacity_stable_turbines) or rt.capacity_stable_turbines
    rt.capacity_total_turbines   = number_or_nil(payload.capacity_total_turbines) or rt.capacity_total_turbines
    if rt.capacity_ready == true then node.capacity_ready = true end
    node.capacity_max   = rt.capacity_max or node.capacity_max
    -- Sobald capacity_max bekannt: Profile-Retry ausloesen wenn power_target=0
    -- runtime ist nicht im direkten Scope — nutze _G.xreactor_runtime
    if (rt.capacity_max or 0) > 0 then
      -- Nutze direkten runtime-Kontext (kein _G-Hack)
      local rt_ref = M._runtime or _G.xreactor_runtime
      if type(rt_ref) == "table" and type(rt_ref.state) == "table"
         and (tonumber(rt_ref.state.power_target) or 0) == 0
         and type(rt_ref.libs) == "table"
         and type(rt_ref.libs.profile_ops) == "table"
         and type(rt_ref.libs.profile_ops.retry_pending_profile) == "function" then
        rt_ref.libs.profile_ops.retry_pending_profile(rt_ref)
      end
    end
    -- Abwärtskompatible Aliase
    node.output        = node.actual_output
    node.power_actual  = node.actual_output
    node.target_output = node.power_target
    rt.power_actual    = rt.actual_output
    rt.output          = rt.actual_output
    rt.target_output   = rt.power_target
  end

  -- Optionale Pocket-Computer-Fernabfrage (Feature, 2026-07-01): siehe
  -- xreactor/optional/pocket_query_handler.lua. pcall(require, ...) sorgt
  -- dafuer, dass bei fehlendem Modul (Feature nicht installiert) einfach
  -- nichts passiert und der normale Dispatch unveraendert weiterlaeuft.
  local ok_pocket_mod, pocket_mod = pcall(require, "optional.pocket_query_handler")
  local pocket_handler = ok_pocket_mod and pocket_mod or nil

  local function build_pocket_snapshot()
    -- Minimaler, robuster Snapshot fuer die Pocket-Antwort — greift nur auf
    -- bereits vorhandene, einfache Zaehlwerte zu, keine teuren Neuberechnungen.
    local rt_active, rt_total = 0, 0
    for _, n in pairs(nodes) do
      if n.role == constants.roles.RT_NODE then
        rt_total = rt_total + 1
        if tostring(n.assignment_state or "") == "active" then rt_active = rt_active + 1 end
      end
    end
    return {
      rt_active = rt_active,
      rt_total = rt_total,
    }
  end

  -- 6-stelliges, alle 5 Minuten rotierendes Token wird am Master-Overview
  -- angezeigt; der Nutzer muss es manuell am Pocket Computer eingeben --
  -- verhindert Steuerbefehle ohne physischen Zugriff auf den Master-Monitor.
  local pocket_token_state = { token = nil, generated_at = 0 }
  local POCKET_TOKEN_TTL_MS = 5 * 60 * 1000
  local function current_pocket_token()
    local now = os.epoch and os.epoch("utc") or 0
    if not pocket_token_state.token or (now - pocket_token_state.generated_at) >= POCKET_TOKEN_TTL_MS then
      math.randomseed(now)
      pocket_token_state.token = tostring(math.random(100000, 999999))
      pocket_token_state.generated_at = now
    end
    return pocket_token_state.token
  end
  -- Für die UI zugänglich machen (Overview zeigt das aktuelle Token an).
  M.get_pocket_token = current_pocket_token

  -- execute_command(action, params): fuehrt die eigentliche Fernsteuerungs-
  -- Aktion aus. Bewusst eine begrenzte, feste Liste erlaubter Aktionen
  -- (kein generischer "eval"-Mechanismus) — jede neue Aktion muss hier
  -- explizit ergaenzt werden.
  local function execute_command(action, params)
    local rt_ref = M._runtime or _G.xreactor_runtime
    if type(rt_ref) ~= "table" or type(rt_ref.state) ~= "table" then
      return false, "Runtime nicht verfuegbar"
    end
    params = params or {}
    if action == "rt_hold_toggle" then
      rt_ref.state.rt_global_off_hold = not (rt_ref.state.rt_global_off_hold == true)
      return true, "RT-Hold jetzt " .. (rt_ref.state.rt_global_off_hold and "AN" or "AUS")
    elseif action == "profile_set" then
      local target = tostring(params.profile or ""):upper()
      if target ~= "BASELOAD" and target ~= "PEAK" and target ~= "IDLE" then
        return false, "Ungueltiges Profil: " .. tostring(params.profile)
      end
      -- Direkt ueber runtime_ops_profile.apply_profile() (derselbe Pfad wie
      -- der "profile"-UI-Button in ui_controller.lua), statt power_target
      -- nur auf 0 zu setzen und auf einen spaeteren sample_trends()-Zyklus
      -- zu hoffen: dieser rechnet den neuen Sollwert nur im Auto-Profil-
      -- Modus neu -- im manuellen Modus blieb power_target sonst dauerhaft
      -- auf 0, bis ein Bediener manuell am physischen UI eingriff.
      if rt_ref.state.rt_global_off_hold then
        return false, "Profil-Wechsel ignoriert: RT-OFF-Hold ist aktiv"
      end
      profile_ops.apply_profile(rt_ref, target)
      return true, "Profil gesetzt: " .. target
    elseif action == "maintenance_toggle" then
      local node_id = params.node_id
      local node = node_id and nodes[node_id]
      if not node then return false, "Node nicht gefunden: " .. tostring(node_id) end
      node.maintenance_mode = not (node.maintenance_mode == true)
      return true, ("Maintenance %s fuer %s"):format(node.maintenance_mode and "AN" or "AUS", tostring(node_id))
    end
    return false, "Unbekannte Aktion: " .. tostring(action)
  end

  local function update_node(message)
    if pocket_handler then
      local ok_handled, handled = pcall(pocket_handler.handle, message, {
        comms = comms(),
        constants = constants,
        log = log,
        build_snapshot = build_pocket_snapshot,
        current_token = current_pocket_token(),
        execute_command = execute_command,
      })
      if ok_handled and handled then return end
    end
    if message.type == constants.message_types.ERROR and message.payload and message.payload.code == "PROTO_MISMATCH" then
      local mismatch_id = utils.normalize_node_id(message.src)
      if mismatch_id ~= "UNKNOWN" then
        nodes[mismatch_id] = nodes[mismatch_id] or { id = mismatch_id, role = "UNKNOWN" }
        nodes[mismatch_id].health = nodes[mismatch_id].health or health.new({})
        nodes[mismatch_id].health.status = health.status.DEGRADED
        nodes[mismatch_id].health.reasons = { [health.reasons.PROTO_MISMATCH] = true }
        nodes[mismatch_id].status = health.status.DEGRADED
        nodes[mismatch_id].last_seen = os.epoch("utc")
        nodes[mismatch_id].last_seen_str = master_time_label()
        nodes[mismatch_id].proto_ver = message.payload.proto_ver
      end
      return
    end

    local sender_id = utils.normalize_node_id(message.sender_id)
    local reported_id = message.node_id and utils.normalize_node_id(message.node_id) or "UNKNOWN"
    local id = (reported_id ~= "UNKNOWN") and reported_id or sender_id
    local role_hint = infer_message_role(message)
    if sender_id ~= "UNKNOWN" and sender_id ~= id and nodes[sender_id] then
      local legacy = nodes[sender_id]
      nodes[sender_id] = nil
      nodes[id] = nodes[id] or legacy
      log(("Node identity remapped: %s -> %s"):format(tostring(sender_id), tostring(id)))
    end
    -- Detect duplicate node_id: same ID, same role, but different sender (different computer)
    local existing = nodes[id]
    if existing and existing.sender_id and sender_id ~= "UNKNOWN"
        and existing.sender_id ~= sender_id
        and existing.last_seen and (os.epoch("utc") - existing.last_seen) < 30000 then
      log(("WARN: Duplicate node_id detected id=%s role=%s existing_sender=%s new_sender=%s -- assign unique node_id in /xreactor/config/node_id.txt"):format(
        tostring(id), tostring(role_hint or normalize_role(message.role)),
        tostring(existing.sender_id), tostring(sender_id)
      ))
    end
    nodes[id] = nodes[id] or { id = id, role = role_hint or normalize_role(message.role), status = constants.status_levels.OFFLINE }
    apply_role_hint(nodes[id], role_hint, "message")
    if nodes[id].down_since then
      local peers = comms() and comms():get_peers() or {}
      local peer = peers and peers[id] or nil
      if not (peer and peer.down) then
        nodes[id].down_since = nil
        log("Node comms restored: " .. tostring(id))
      end
    end

    nodes[id].id = id
    if reported_id ~= "UNKNOWN" then nodes[id].node_id = reported_id end
    nodes[id].sender_id = sender_id ~= "UNKNOWN" and sender_id or nodes[id].sender_id
    nodes[id].last_seen = os.epoch("utc")
    nodes[id].last_seen_str = master_time_label()
    nodes[id].proto_ver = message.proto_ver
    nodes[id].managed = true
    nodes[id].stale = false
    nodes[id].offline = false
    nodes[id].recovering = false

    if message.type == constants.message_types.HELLO or message.type == constants.message_types.REGISTER then
      if nodes[id].status == constants.status_levels.OFFLINE then log("Node online: " .. tostring(id)) end
      assign_node_status_from_health(nodes[id], "hello")
      nodes[id].state = constants.node_states.OFF
      if nodes[id].role == constants.roles.RT_NODE then sequencer:enqueue(id) end
      mark_rt_sync_dirty(nodes[id], "hello")
    elseif message.type == constants.message_types.HEARTBEAT then
      nodes[id].state = message.payload.state
      nodes[id].down_since = nil
      nodes[id].offline = false
      nodes[id].stale = false
      nodes[id].managed = true
      nodes[id].recovering = false
      -- manifest_version pro Node speichern, damit die AUX-Monitor
      -- "Updates"-Seite sehen kann, ob alle Nodes dieselbe Version haben.
      if message.payload.manifest_version ~= nil then
        nodes[id].manifest_version = tonumber(message.payload.manifest_version)
        nodes[id].manifest_version_seen_ts = message.ts or (os.epoch and os.epoch("utc")) or 0
      end
      if nodes[id].health and nodes[id].health.reasons and nodes[id].health.reasons[health.reasons.COMMS_DOWN] then
        nodes[id].health.reasons[health.reasons.COMMS_DOWN] = nil
        log(("Node %s reason removed: %s (heartbeat)"):format(id, health.reasons.COMMS_DOWN))
      end
      assign_node_status_from_health(nodes[id], "heartbeat")
      mark_rt_sync_dirty(nodes[id], "heartbeat")
    elseif message.type == constants.message_types.STATUS then
      local previous_mode = nodes[id].mode
      nodes[id] = utils.merge(nodes[id], message.payload)
      apply_role_hint(nodes[id], role_hint or (payload_looks_rt(message.payload) and constants.roles.RT_NODE or nil), "status")
      nodes[id].payload = message.payload
      if nodes[id].role == constants.roles.ENERGY_NODE then
        nodes[id].energy = message.payload.energy or message.payload
      elseif nodes[id].role == constants.roles.RT_NODE then
        populate_rt_status(nodes[id], message.payload)
      else
        support_status.apply(nodes[id], message.payload, constants)
      end
      local previous_health_status = nodes[id].health and nodes[id].health.status or nil
      local previous_reasons = nodes[id].health and nodes[id].health.reasons or nil
      if message.payload.health then
        nodes[id].health = message.payload.health
        if previous_health_status ~= message.payload.health.status then
          log(("Node %s health %s -> %s (status payload)"):format(id, tostring(previous_health_status or "UNKNOWN"), tostring(message.payload.health.status or "UNKNOWN")))
        end
        local old_reasons = format_reasons(previous_reasons)
        local new_reasons = format_reasons(message.payload.health.reasons)
        if old_reasons ~= new_reasons then
          log(("Node %s reasons %s -> %s"):format(id, old_reasons, new_reasons))
        end
        assign_node_status_from_health(nodes[id], "status")
      else
        nodes[id].status = message.payload.status or nodes[id].status
      end
      nodes[id].bindings = message.payload.bindings or nodes[id].bindings
      nodes[id].bindings_summary = message.payload.bindings_summary or nodes[id].bindings_summary
      nodes[id].capabilities = message.payload.capabilities or nodes[id].capabilities
      nodes[id].mode = message.payload.mode or nodes[id].mode
      nodes[id].registry = message.payload.registry or nodes[id].registry
      nodes[id].last_error = message.payload.last_error or nodes[id].last_error
      nodes[id].last_error_ts = message.payload.last_error_ts or nodes[id].last_error_ts
      -- Fix P7: doppelter populate_rt_status Aufruf entfernt (war auch vor health-Block)
      if previous_mode and nodes[id].mode and previous_mode ~= nodes[id].mode then
        log(("Node %s mode: %s"):format(id, tostring(nodes[id].mode)))
      end
      if sequencer.active and sequencer.active.node_id == id then
        if message.payload.modules then
          local module = message.payload.modules[sequencer.active.module_id]
          if not module then
            utils.log("SEQ", ("WARN: module %s missing from status, waiting"):format(sequencer.active.module_id))
            return
          end
          if module.state == "STABLE" then
            sequencer:notify_stable(id, sequencer.active.module_id, module.state)
          else
            utils.log("SEQ", ("Waiting for module %s, state=%s"):format(sequencer.active.module_id, module.state or "UNKNOWN"))
          end
        elseif nodes[id].state == constants.node_states.RUNNING then
          sequencer:notify_stable(id, sequencer.active.module_id, nodes[id].state)
        end
      end
      mark_rt_sync_dirty(nodes[id], "status")
    -- Markiert einen laufenden Config-Editor-Edit-Ziel-Eintrag als
    -- DELIVERED, sonst No-Op -- ohne diesen Zweig faellt ACK_DELIVERED in
    -- den "else"-Zweig und loest einen falschen "Unknown message type"-WARN aus.
    elseif message.type == constants.message_types.ACK_DELIVERED then
      if config_edits_state then
        local changed = config_edits_lib.handle_ack_delivered(config_edits_state, message)
        if changed and on_config_edit_change then on_config_edit_change() end
      end
    elseif message.type == constants.message_types.ACK_APPLIED then
      local result = message.payload and message.payload.result or {}
      local redundant_setpoint_ack = ack_matches_last_setpoints(nodes[id], result)
      nodes[id].last_command_result = {
        ok = result.ok ~= false,
        error = result.error,
        reason_code = result.reason_code,
        module_id = result.module_id,
        ack_for = message.ack_for,
        at = os.epoch("utc"),
        command_target = result.command_target,
        command_value = result.command_value,
        transition = result.transition,
        desired_node_state = result.desired_node_state,
        shutdown_stage = result.shutdown_stage
      }
      nodes[id].last_command_error = result.ok == false and (result.error or "unknown") or nil
      if result.ok == false then
        local reason_code = result.reason_code or ""
        -- CAPACITY_LEARNING ist kein Fehler sondern temporärer Zustand — kein WARN
        if reason_code == "CAPACITY_LEARNING" then
          log(("Command skipped on %s: %s (capacity learning in progress)"):format(id, result.error or ""), "INFO")
        else
          log(("Command failed on %s: %s"):format(id, result.error or "unknown"), "WARN")
        end
      end
      sequencer:notify_ack(id, result.module_id)
      local workflow_stage = nodes[id].shutdown_workflow and nodes[id].shutdown_workflow.stage or nil
      local workflow_waiting = workflow_stage == "REQUEST_STATE" or workflow_stage == "REQUESTED" or workflow_stage == "WAITING_STATE"
      local ack_transition = tostring(result.transition or "")
      local needs_workflow_followup = workflow_waiting and (
        result.ok == false or ack_transition == "REQUESTED" or ack_transition == "ALREADY_IN_STATE" or ack_transition == "APPLIED"
      )
      if not redundant_setpoint_ack or needs_workflow_followup then
        mark_rt_sync_dirty(nodes[id], "ack_applied")
      else
        log(("Node %s ACK_APPLIED deduped: unchanged setpoint ack does not re-dirty"):format(tostring(id)))
      end
      -- Korreliert dieses ACK_APPLIED gegen einen evtl. laufenden
      -- Config-Editor-Edit (per message_id/ack_for).
      if config_edits_state then
        local changed = config_edits_lib.handle_ack_applied(config_edits_state, message)
        if changed and on_config_edit_change then on_config_edit_change() end
      end
    elseif message.type == constants.message_types.ALERT_SUMMARY then
      -- Alert summary payload can be routed to the alert service in later iterations.
    else
      add_alarm(id, "WARN", "Unknown message type " .. tostring(message.type))
    end
  end

  return { update_node = update_node }
end

-- set_runtime: direkten runtime-Zugriff ermöglichen ohne _G
function M.set_runtime(runtime)
  M._runtime = runtime
end

return M
