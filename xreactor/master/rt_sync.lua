local constants = require("shared.constants")
local utils = require("core.utils")

local M = {}

-- P1: number_or_nil aus utils, number_or als lokaler Wrapper mit Fallback
-- number_or_nil aus utils, mit Fallback für ältere utils-Versionen
local number_or_nil = utils.number_or_nil or function(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then local n = tonumber(v); if n then return n end end
  return nil
end
local function number_or(value, fallback)
  return number_or_nil(value) or fallback
end

local function normalize_node_mode(mode)
  if mode == nil then return "UNKNOWN" end
  return tostring(mode)
end

local function normalize_mode_key(mode)
  if mode == nil then return "UNKNOWN" end
  return tostring(mode):upper()
end

local function sort_by_priority_then_id(a, b)
  if (a.priority or 0) == (b.priority or 0) then
    return (a.id or "") < (b.id or "")
  end
  return (a.priority or 0) > (b.priority or 0)
end

-- P2: node_capacity gibt 0 zurück wenn der Node noch einlernt (capacity_ready=false).
-- Damit rechnet der Master nicht mit einem falschen Platzhalter-Wert.
-- Der Node wird mit 0% angesteuert bis sein echter Wert vorliegt.
local function node_capacity_ready(node)
  local rt = node and node.rt or {}
  if rt.capacity_ready == true then return true end
  if node and node.capacity_ready == true then return true end
  return false
end

local function node_capacity(node)
  -- Kein Fallback: Kapazität kommt ausschliesslich vom Capacity-Learning
  -- der RT-Node. Solange noch nicht eingelernt gilt capacity=0 und die
  -- Node wird nicht zugeteilt. Ein fixer Fallback-Wert (z.B. 3000 RF/t)
  -- wäre bei realen Reaktoren (5-50 MRF/t) um Grössenordnungen falsch und
  -- würde die Prozent-Berechnung komplett verfälschen.
  if not node_capacity_ready(node) then
    return 0, "learning"
  end
  local capacity = number_or(node and node.capacity_max, nil)
    or number_or(node and node.rt and node.rt.capacity_max, nil)
    or number_or(node and node.measured_capacity_max, nil)
  if capacity and capacity > 0 then
    return capacity, "measured"
  end
  return 0, "learning"
end

-- Nur steuerungsrelevante Felder — RT-Node regelt Flow, Coil, Reaktor-Stab
-- vollständig autonom aus power_target_percent. Redundante Felder entfernt:
--   target_rpm      → RT nutzt immer CONFIG.TARGET_RPM (900)
--   steam_target    → Reaktor regelt autonom über Steam-Margin-Regler
--   power_target    → RT nutzt nur den Prozentwert, nicht den absoluten RF/t
--   enable_reactors/turbines → folgen aus assignment_state via State-Machine
--   assignment_reason/source/rank/controllable → reine Diagnose-Felder
function M.normalize_setpoints(setpoints)
  local payload = setpoints or {}
  return {
    power_target_percent = payload.power_target_percent,
    assignment_state     = payload.assignment_state,
    shutdown_stage       = payload.shutdown_stage,
    desired_node_state   = payload.desired_node_state,
  }
end

function M.send_rt_mode(comms, node, mode)
  if not node or not mode then return end
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_MODE or constants.command_targets.MODE,
    value = mode
  }, { requires_applied = true })
  node.last_mode_request = os.epoch("utc")
  node.last_mode_request_mode = mode
  node.desired_mode = mode
end

function M.send_rt_setpoints(comms, node, setpoints)
  if not node then return end
  local payload = M.normalize_setpoints(setpoints)
  comms:send_command(utils.normalize_node_id(node.id), {
    target = constants.command_targets.SET_SETPOINTS or constants.command_targets.POWER_TARGET,
    value = payload
  }, { requires_applied = true })
  node.last_setpoints = payload
  node.last_setpoints_ts = os.epoch("utc")
end

-- P6: same_setpoints() vergleicht nur funktionale Felder.
-- assignment_reason und assignment_source sind interne Bezeichner;
-- eine Änderung dort soll kein neues Paket auslösen.
function M.same_setpoints(a, b)
  if not a or not b then return false end
  return a.power_target_percent == b.power_target_percent
     and a.assignment_state     == b.assignment_state
     and a.shutdown_stage       == b.shutdown_stage
     and a.desired_node_state   == b.desired_node_state
end

function M.set_default_mode(ctx, node)
  local mode = node.desired_mode or ctx.config.rt_default_mode or "MASTER"
  M.send_rt_mode(ctx.comms, node, mode)
end

local function mode_sync_action(ctx, node, now)
  local desired = node and (node.desired_mode or (ctx.config and ctx.config.rt_default_mode) or "MASTER") or "MASTER"
  if desired == nil or tostring(desired) == "" then return nil, nil, "NO_DESIRED_MODE" end

  local current_key = normalize_mode_key(node and node.mode)
  local desired_key = normalize_mode_key(desired)
  if current_key == desired_key then return nil, desired, "MODE_OK" end

  local status = node and node.status or constants.status_levels.OFFLINE
  local state = node and node.state or constants.node_states.OFF
  if status == constants.status_levels.OFFLINE then return "blocked", desired, "OFFLINE" end
  if status == constants.status_levels.EMERGENCY or state == constants.node_states.EMERGENCY or state == constants.node_states.SAFE then
    return "blocked", desired, "SAFE_OR_EMERGENCY"
  end

  local last_mode_ts = tonumber(node and node.last_mode_request) or 0
  local last_mode = normalize_mode_key(node and node.last_mode_request_mode)
  local retry_gap_ms = 3000
  if last_mode == desired_key and last_mode_ts > 0 and (now - last_mode_ts) < retry_gap_ms then
    return "wait", desired, "MODE_REQUEST_PENDING"
  end
  return "send", desired, "MODE_MISMATCH_" .. current_key
end

function M.evaluate_rt_node(node, opts)
  opts = opts or {}
  local hold = opts.rt_global_off == true
  local mode = normalize_node_mode(node and node.mode)
  local status = node and node.status or constants.status_levels.OFFLINE
  local state = node and node.state or constants.node_states.OFF
  -- Fix #4: actual_output kanonisch, power_actual + output Fallback
  local output = node and (number_or(node.actual_output, nil) or number_or(node.power_actual, nil) or number_or(node.output, 0)) or 0
  if hold then
    return { controllable = false, reason = "GLOBAL_HOLD", mode = mode, status = status, state = state, output = output }
  end
  if mode ~= "MASTER" then
    return { controllable = false, reason = "MODE_" .. mode, mode = mode, status = status, state = state, output = output }
  end
  if status == constants.status_levels.EMERGENCY or state == constants.node_states.EMERGENCY or state == constants.node_states.SAFE then
    return { controllable = false, reason = "SAFE_OR_EMERGENCY", mode = mode, status = status, state = state, output = output }
  end
  if status == constants.status_levels.OFFLINE then
    return { controllable = false, reason = "OFFLINE", mode = mode, status = status, state = state, output = output }
  end
  if state == constants.node_states.OFF then
    return { controllable = false, reason = "STARTUP_PENDING", mode = mode, status = status, state = state, output = output }
  end
  return { controllable = true, reason = "ACTIVE", mode = mode, status = status, state = state, output = output }
end

function M.build_node_setpoint_plan(ctx)
  local nodes = ctx.nodes or {}
  local config = ctx.config or {}
  local base = config.rt_setpoints or {}
  local global_target = math.max(0, number_or(ctx.power_target, 0))
  local hold = ctx.rt_global_off == true
  local now = os.epoch("utc")
  local plan = {}
  local active, pending_startup = {}, {}
  local startup_margin = math.max(0, number_or(base.startup_margin_power, 0))

  for _, node in pairs(nodes) do
    if node.role == constants.roles.RT_NODE then
      local eval = M.evaluate_rt_node(node, { rt_global_off = hold })
      local shutdown = node and node.shutdown_workflow or {}
      local capacity, capacity_source = node_capacity(node)
      local entry = {
        node = node,
        eval = eval,
        id = utils.normalize_node_id(node.id),
        mode = eval.mode,
        status = eval.status,
        capacity = capacity,
        capacity_source = capacity_source,
        assigned_power = 0,
        assigned_percent = 0,
        assignment_rank = nil,
        assignment_reason = eval.reason,
        assignment_state = "unavailable",
        controllable = eval.controllable == true,
        startup_eligible = eval.reason == "STARTUP_PENDING",
        priority = math.max(0, number_or(eval.output, 0)),
        shutdown_requested_at = shutdown.requested_at,
        shutdown_stage = shutdown.stage,
        shutdown_ready_at = shutdown.ready_at
      }
      table.insert(plan, entry)
      if entry.controllable then table.insert(active, entry) end
      if entry.startup_eligible then table.insert(pending_startup, entry) end
    end
  end

  table.sort(plan, function(a, b) return (a.id or "") < (b.id or "") end)
  table.sort(active, sort_by_priority_then_id)
  table.sort(pending_startup, function(a, b) return (a.id or "") < (b.id or "") end)

  local remaining = global_target
  local needed_nodes = 0
  local capacity_seen = 0
  for _, entry in ipairs(active) do
    if remaining > 0 then
      needed_nodes = needed_nodes + 1
      capacity_seen = capacity_seen + entry.capacity
      remaining = math.max(0, remaining - entry.capacity)
    end
  end
  if remaining > startup_margin then
    for _, entry in ipairs(pending_startup) do
      if remaining > startup_margin then
        needed_nodes = needed_nodes + 1
        capacity_seen = capacity_seen + entry.capacity
        remaining = math.max(0, remaining - entry.capacity)
      end
    end
  end
  -- Proportionale Zuweisung: nur die benötigten Nodes werden aktiviert,
  -- und diese bekommen alle denselben Prozentsatz.
  --
  -- Ablauf:
  --   1. Sortiere nach Kapazität (grösste zuerst) — damit werden immer die
  --      leistungsstärksten Nodes bevorzugt, nicht zufällig die mit dem
  --      aktuell höchsten Output.
  --   2. Zähle wie viele Nodes für global_target nötig sind (greedy).
  --   3. Verteile global_target gleichmässig NUR auf die benötigten Nodes:
  --        uniform_pct = global_target / sum(benötigte Kapazitäten) × 100
  --   4. Nicht benötigte Nodes: SHED/standby.
  --
  -- Vorteile:
  --   - Gleichmässige Auslastung (kein Reaktor dauerhaft auf 100%)
  --   - Kein Yo-Yo-Effekt
  --   - Bei 1 Node: identisches Ergebnis wie vorher
  --   - Skaliert korrekt auf N Nodes mit unterschiedlichen Kapazitäten

  -- Nodes nach Kapazität sortieren (grösste zuerst)
  table.sort(active, function(a, b)
    if a.capacity ~= b.capacity then return a.capacity > b.capacity end
    return (a.id or "") < (b.id or "")
  end)

  -- Summe der Kapazitäten der benötigten Nodes
  local needed_capacity = 0
  for i = 1, needed_nodes do
    if active[i] then needed_capacity = needed_capacity + active[i].capacity end
  end
  local uniform_pct = needed_capacity > 0
    and math.min(100, global_target / needed_capacity * 100)
    or 0

  local keep_count = math.min(#active, needed_nodes)

  for idx, entry in ipairs(active) do
    entry.assignment_rank = idx
    if idx <= keep_count then
      entry.assigned_percent = uniform_pct
      entry.assigned_power   = entry.capacity * uniform_pct / 100
      entry.assignment_state  = "active"
      entry.assignment_reason = "PROPORTIONAL_ACTIVE"
    else
      entry.assigned_power    = 0
      entry.assigned_percent  = 0
      entry.assignment_rank   = idx
      if idx == keep_count + 1 then
        local ready_at = entry.shutdown_ready_at or 0
        local requested_at = entry.shutdown_requested_at or now
        local ramp_ms = math.max(1000, number_or(base.shutdown_ramp_ms, 6000))
        if ready_at <= 0 then ready_at = requested_at + ramp_ms end
        local shutdown_ready = now >= ready_at
        entry.assignment_state  = shutdown_ready and "shutdown" or "shed"
        entry.assignment_reason = shutdown_ready and "SHUTDOWN_READY" or "SHED_EXCESS_CAPACITY"
      else
        entry.assignment_state  = "standby"
        entry.assignment_reason = "STANDBY"
      end
    end
  end

  local startup_candidate = nil
  local missing_active_nodes = needed_nodes - #active
  if missing_active_nodes > 0 and #pending_startup > 0 and remaining > startup_margin then
    startup_candidate = pending_startup[1]
    startup_candidate.assignment_reason = "STARTUP_NEEDED"
    startup_candidate.assignment_state = "startup"
    startup_candidate.assignment_rank = keep_count + 1
  end

  for _, entry in ipairs(pending_startup) do
    if entry ~= startup_candidate then
      entry.assignment_reason = "STARTUP_WAIT"
      entry.assignment_state = "standby"
      entry.assigned_power = 0
      entry.assigned_percent = 0
    end
  end

  local shutdown_candidate = nil
  for _, entry in ipairs(active) do
    if entry.assignment_reason == "SHED_EXCESS_CAPACITY" then
      shutdown_candidate = entry
      break
    end
  end

  for _, entry in ipairs(plan) do
    local enabled = entry.controllable and not hold and entry.assignment_state == "active"
    local desired_node_state = nil
    if entry.assignment_state == "shutdown" then
      desired_node_state = constants.node_states.OFF
    elseif entry.assignment_state == "standby" or entry.assignment_state == "shed" then
      desired_node_state = constants.node_states.LIMITED
    end
    entry.setpoints = M.normalize_setpoints({
      power_target_percent = enabled and entry.assigned_percent or 0,
      assignment_state     = entry.assignment_state,
      shutdown_stage       = entry.assignment_state == "shutdown" and "REQUEST_OFF"
                             or (entry.assignment_state == "shed" and "RAMPDOWN" or nil),
      desired_node_state   = desired_node_state,
    })
  end

  return {
    nodes = plan,
    global_target = global_target,
    hold = hold,
    controllable_count = #active + #pending_startup,
    required_nodes = needed_nodes,
    startup_candidate_id = startup_candidate and startup_candidate.id or nil,
    shutdown_candidate_id = shutdown_candidate and shutdown_candidate.id or nil,
    capacity_seen = capacity_seen
  }
end

function M.sync_rt_node(ctx, node)
  if node.role ~= constants.roles.RT_NODE then return end
  local now = os.epoch("utc")
  local node_id = utils.normalize_node_id(node.id)
  local mode_action, desired_mode, mode_reason = mode_sync_action(ctx, node, now)
  if mode_action == "send" then
    if ctx.log then
      ctx.log(("RT mode request node=%s current=%s desired=%s reason=%s"):format(
        tostring(node_id), tostring(node.mode or "UNKNOWN"), tostring(desired_mode), tostring(mode_reason)
      ), "INFO")
    end
    M.send_rt_mode(ctx.comms, node, desired_mode)
    return
  elseif mode_action == "wait" then
    if ctx.log then
      ctx.log(("RT setpoint sync deferred node=%s current=%s desired=%s reason=%s"):format(
        tostring(node_id), tostring(node.mode or "UNKNOWN"), tostring(desired_mode), tostring(mode_reason)
      ), "DEBUG")
    end
    return
  elseif mode_action == "blocked" then
    if ctx.log then
      ctx.log(("RT mode request blocked node=%s current=%s desired=%s reason=%s"):format(
        tostring(node_id), tostring(node.mode or "UNKNOWN"), tostring(desired_mode), tostring(mode_reason)
      ), "WARN")
    end
  end

  local plan = ctx.plan or M.build_node_setpoint_plan(ctx)
  local assigned = nil
  for _, entry in ipairs(plan.nodes or {}) do
    if entry.id == node_id then assigned = entry break end
  end
  if not assigned then return end
  local desired = assigned.setpoints
  local trigger = tostring(ctx.trigger or "unknown")

  -- Fix: assignment_state wurde NUR geschrieben, wenn ein neues Funk-Command
  -- tatsächlich gesendet wurde (siehe send_rt_setpoints -> node.last_setpoints).
  -- Bei ACK_MATCH/Dedup (der HÄUFIGSTE Fall im Normalbetrieb — kein neues
  -- Command nötig weil die Node schon den richtigen Wert hat) blieb
  -- node.assignment_state für die UI dauerhaft leer/UNASSIGNED, obwohl der
  -- Master intern längst korrekt "active"/ASSIGNED plant. Jetzt: der Plan-
  -- Wert wird bei JEDEM sync_rt_node()-Lauf in node geschrieben, unabhängig
  -- vom Dedup-Pfad — Dedup spart nur den Funkversand, nicht die UI-Daten.
  node.assignment_state = assigned.assignment_state
  node.assignment_reason = assigned.assignment_reason
  node.control_source = assigned.mode
  node.capacity_source = assigned.capacity_source
  if ctx.log then
    ctx.log(("RT plan node=%s trigger=%s state=%s controllable=%s reason=%s assigned=%.2f percent=%.1f capacity=%.2f source=%s mode=%s status=%s"):format(
      tostring(node_id), trigger, tostring(desired.assignment_state), tostring(assigned.controllable), tostring(assigned.assignment_reason), tonumber(desired.power_target) or 0,
      tonumber(desired.power_target_percent) or 0, tonumber(assigned.capacity) or 0, tostring(assigned.capacity_source),
      tostring(assigned.mode), tostring(assigned.status)
    ), assigned.controllable and "INFO" or "WARN")
  end
  -- Setpoint immer senden.
  if ctx.log then
    ctx.log(("RT setpoints send node=%s trigger=%s pct=%.1f state=%s"):format(
      tostring(node_id), trigger,
      tonumber(desired.power_target_percent) or 0,
      tostring(desired.assignment_state)
    ), "INFO")
  end
  M.send_rt_setpoints(ctx.comms, node, desired)
end

return M