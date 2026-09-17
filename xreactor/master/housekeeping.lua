local M = {}
local config_edits_lib = require("master.config_edits")

function M.handle_command_timeouts(opts)
  local constants = opts.constants
  local utils = opts.utils
  local comms = opts.comms
  local nodes = opts.nodes
  local log = opts.log
  local config_edits_state = opts.config_edits_state
  local on_config_edit_change = opts.on_config_edit_change
  local timeouts = comms:consume_timeouts() or {}
  for _, entry in ipairs(timeouts) do
    local msg = entry.message or {}
    if msg.type == constants.message_types.COMMAND then
      local node_id = utils.normalize_node_id(msg.dst or (msg.payload and msg.payload.target))
      if node_id ~= "UNKNOWN" then
        nodes[node_id] = nodes[node_id] or { id = node_id, role = "UNKNOWN", status = constants.status_levels.OFFLINE }
        local command = msg.payload and msg.payload.command or {}
        nodes[node_id].last_command_result = {
          ok = false,
          error = "ack timeout",
          reason_code = "ACK_TIMEOUT",
          ack_for = msg.message_id,
          at = os.epoch("utc"),
          command_target = command.target,
          command_value = command.value
        }
        nodes[node_id].last_command_error = "ack timeout"
        log(("Command timeout for %s (%s)"):format(tostring(node_id), tostring(command.target or "unknown")), "WARN")
      end
      if config_edits_state then
        local changed = config_edits_lib.handle_timeout(config_edits_state, msg.message_id)
        if changed and on_config_edit_change then on_config_edit_change() end
      end
    end
  end
end

function M.build_master_alert_payload(alert_service, config)
  local by_node = {}
  local limit = config.alert_node_top_n or 3
  local active = alert_service and alert_service:get_active() or {}
  for _, alert in ipairs(active) do
    local node_id = alert.source and alert.source.node_id
    if node_id then
      local entry = by_node[node_id] or { critical = 0, top = {} }
      if alert.severity == "CRITICAL" then entry.critical = entry.critical + 1 end
      if #entry.top < limit then
        table.insert(entry.top, { severity = alert.severity, title = alert.title, message = alert.message, code = alert.code })
      end
      by_node[node_id] = entry
    end
  end
  return { alerts = { ts = os.epoch("utc"), by_node = by_node } }
end

local function normalize_rt_capacity_truth(runtime)
  local constants = runtime.libs.constants
  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.RT_NODE then
      local rt = type(node.rt) == "table" and node.rt or nil
      local cap = tonumber(node.capacity_max)
        or tonumber(rt and rt.capacity_max)
        or 0
      -- message_handlers historically only ever set capacity_ready to true.
      -- RT explicitly publishes max=0 whenever learning is invalidated, so
      -- that state is authoritative proof that "ready" must be false too.
      -- Clearing both mirrors prevents UI/diagnostics from advertising a
      -- remembered ready state after topology invalidation.
      if cap <= 0 then
        node.capacity_ready = false
        if rt then rt.capacity_ready = false end
      elseif rt and rt.capacity_ready == false then
        node.capacity_ready = false
      end
    end
  end
end

-- Diagnose fuer "Service tick slow: HOUSEKEEPING took Xms"-Meldungen
-- (siehe service_manager.lua): dessen Warnung nennt nur den Gesamtwert
-- fuer den ganzen HOUSEKEEPING-Tick, nicht welcher der sechs Teilschritte
-- unten dafuer verantwortlich war. Beobachtet 2026-09-17 beim gemeldeten
-- "sieht aus wie Kommunikationsprobleme, alle offline": HOUSEKEEPING nahm
-- einmalig 24921ms, "Service manager tick slow" davor sogar bis zu 25650ms
-- -- waehrend eines so langen, ununterbrochenen synchronen Lua-Aufrufs kann
-- der MASTER (CC:Tweaked ist kooperativ-single-threaded) keine
-- modem_message-Events verarbeiten und sendet in dieser Zeit auch selbst
-- keine Heartbeats/Status-Broadcasts mehr -- jeder Knoten (RT, alle VALVE-
-- Knoten) erkennt das dann ganz korrekt als "Peer down: node-53 (MASTER)"
-- fuer die Dauer des Stalls, obwohl das Funknetz selbst nichts abbekommen
-- hat. Kein Netzwerkfehler, sondern ein zu langer blockierender Tick.
-- Diese Sub-Timer pinpointen beim naechsten Auftreten, welcher der
-- Teilschritte (voraussichtlich sequencer:tick oder rt_ops.check_timeouts,
-- da beide ueber alle Knoten iterieren) den Block tatsaechlich verursacht,
-- statt weiter zu raten.
local SUBSTEP_WARN_MS = 500

local function timed(runtime, name, fn)
  local started = os.epoch and os.epoch("utc") or (os.clock() * 1000)
  fn()
  local duration = (os.epoch and os.epoch("utc") or (os.clock() * 1000)) - started
  if duration > SUBSTEP_WARN_MS then
    runtime.log(("HOUSEKEEPING substep slow: %s took %dms (threshold=%dms)"):format(
      name, duration, SUBSTEP_WARN_MS), "WARN")
  end
end

function M.tick(runtime)
  timed(runtime, "handle_command_timeouts", function()
    M.handle_command_timeouts({
      constants = runtime.libs.constants,
      utils = runtime.libs.utils,
      comms = runtime.refs.comms,
      nodes = runtime.state.nodes,
      log = runtime.log,
      config_edits_state = runtime.state.config_edits,
      on_config_edit_change = runtime.persist_config_edits
    })
  end)
  timed(runtime, "normalize_rt_capacity_truth", function()
    normalize_rt_capacity_truth(runtime)
  end)
  if runtime.refs.sequencer then
    timed(runtime, "sequencer:tick", function()
      runtime.refs.sequencer:tick(runtime.state.nodes)
    end)
  end
  if runtime.flush_rt_sync_queue then
    timed(runtime, "flush_rt_sync_queue", function()
      runtime.flush_rt_sync_queue()
    end)
  end
  local rt_ops = runtime.libs.rt_ops
  if rt_ops then
    timed(runtime, "rt_ops.check_timeouts", function()
      rt_ops.check_timeouts(runtime)
    end)
  end
  local profile_ops = runtime.libs.profile_ops
  if profile_ops then
    timed(runtime, "profile_ops.sample_trends", function()
      profile_ops.sample_trends(runtime)
    end)
  end
  local fuel_relay = runtime.libs.fuel_relay
  if fuel_relay then
    timed(runtime, "fuel_relay.tick", function()
      fuel_relay.tick(runtime)
    end)
  end
end

return M
