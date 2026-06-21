-- master/runtime_ops_profile.lua
--
-- ════════════════════════════════════════════════════════════════════════
-- DATENFLUSS: power_target -> RT-Node Setpoint (vollständige Kette)
-- ════════════════════════════════════════════════════════════════════════
-- Diese Datei ist NUR der erste Schritt einer Kette über 4 Dateien. Wer
-- hier etwas ändert, sollte den gesamten Fluss kennen — sonst entstehen
-- wieder schwer auffindbare Bugs wie der SHED-Selbstverstärkungs-Loop
-- (siehe estimate_base_power(), Fix v100).
--
-- 1) runtime_ops_profile.lua (DIESE DATEI)
--    M.sample_trends(runtime)   — läuft periodisch über housekeeping.lua,
--      berechnet energy_pct aus den Energy-Node-Daten und wechselt bei
--      Schwellenüberschreitung automatisch das Profil (BASELOAD/PEAK/IDLE),
--      falls runtime.state.auto_profile == true (siehe v76/v78 Fixes —
--      vorher blieb power_target ohne Trigger für immer bei 0).
--    M.apply_profile(runtime, name)
--      -> ruft M.estimate_base_power(runtime) auf, um eine RF/t-Basis zu
--         bekommen, dann: runtime.state.power_target = base * profile.target
--      -> estimate_base_power() Priorität: 1) measured_total (Summe der
--         tatsächlichen RT-Node-Outputs) 2) learned_capacity_total (Summe
--         der gelockten Capacity-Learning-Werte — Fix v100, verhindert dass
--         eine kurzzeitig auf 0 RF/t stehende Node fälschlich als
--         "Kapazitätsüberschuss" markiert wird) 3) runtime.state.power_target
--         (vorheriger Wert) 4) capacity-fallback (generischer Wert,
--         standardmäßig winzig — nur Notlösung wenn NICHTS bekannt ist)
--
-- 2) master/rt_sync.lua
--    Liest runtime.state.power_target als ctx.power_target (= global_target).
--    Verteilt das auf alle aktiven RT-Nodes proportional zu ihrer
--    node_capacity() (siehe node_capacity_ready() dort — prüft
--    rt.capacity_ready / node.capacity_ready, siehe Punkt 4 unten).
--    Berechnet pro Node: assigned_power, assigned_percent, assignment_state
--    ("active" / "shed" / "shutdown" / "startup" / "standby" / "unavailable").
--    Baut daraus das SET_SETPOINTS Command-Payload (inkl. assignment_state,
--    power_target_percent, rpm, steam, enable_reactors).
--
-- 3) master/rt_sync_coalescer.lua
--    Bündelt mehrere Setpoint-Änderungen in einem kurzen Zeitfenster (statt
--    bei jeder kleinen Schwankung sofort ein neues Command zu senden) —
--    vergleicht alte/neue Werte (siehe a.power_target == b.power_target
--    Vergleichslogik dort) um unnötige Funk-Last zu vermeiden.
--
-- 4) Auf der RT-Node: nodes/rt/command_handler.lua empfängt SET_SETPOINTS,
--    schreibt die Felder in runtime_ctx.targets (targets.power,
--    targets.power_percent, targets.rpm, targets.assignment_state — siehe
--    Fix v97, assignment_state wurde vorher nur geloggt, nie gespeichert).
--    nodes/rt/monitor_ui.lua liest targets.* für die Anzeige (model.target_power
--    etc.) und sendet via status_snapshot.lua periodisch capacity_ready /
--    capacity_max zurück an den Master — WICHTIG: capacity_ready landet im
--    Master NICHT über einen expliziten Zuweisungs-Code, sondern automatisch
--    über das generische utils.merge(nodes[id], message.payload) in
--    master/message_handlers.lua (Zeile mit payload_looks_rt) — das war beim
--    ersten Durchverfolgen dieser Kette nicht offensichtlich.
--
-- KURZ: power_target (hier) -> assigned_percent (rt_sync.lua)
--       -> SET_SETPOINTS (rt_sync_coalescer.lua, gebündelt)
--       -> targets.* (RT command_handler.lua)
--       -> UI-Anzeige + capacity_ready zurück an Master (via utils.merge,
--          NICHT explizit zugewiesen)
-- ════════════════════════════════════════════════════════════════════════

local M = {}

local function number_or(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then return parsed end
  end
  return fallback
end

function M.estimate_base_power(runtime)
  local measured_total = 0
  local learned_capacity_total = 0
  local rt_count = 0
  local available_count = 0
  local constants = runtime.libs.constants
  for _, node in pairs(runtime.state.nodes) do
    if node.role == constants.roles.RT_NODE then
      rt_count = rt_count + 1
      -- Fix #4: actual_output kanonisch; power_actual + output als Fallback
      local output = number_or(node.actual_output, nil) or number_or(node.power_actual, nil) or number_or(node.output, 0)
      measured_total = measured_total + output
      -- Fix: gelernte Kapazität (vom Capacity-Learning auf der RT-Node)
      -- separat aufsummieren — DAS ist der realistische Maßstab für eine
      -- Node die gerade 0 RF/t liefert (z.B. weil sie im letzten SHED-Zyklus
      -- heruntergefahren wurde), nicht der winzige generische Fallback-Wert.
      local capacity_ready = (node.rt and node.rt.capacity_ready == true) or node.capacity_ready == true
      if capacity_ready then
        local cap = number_or(node.capacity_max, nil) or number_or(node.rt and node.rt.capacity_max, nil)
        if cap then learned_capacity_total = learned_capacity_total + cap end
      end
      local status = tostring(node.status or ""):upper()
      if status ~= tostring(constants.status_levels.OFFLINE):upper() then
        available_count = available_count + 1
      end
    end
  end
  if measured_total > 0 then return measured_total, "measured" end
  -- Fix: gelernte Kapazität ist ein deutlich realistischerer Schätzwert als
  -- der generische capacity-fallback (3000 RF/t Default — vernachlässigbar
  -- gegenüber realen Reaktor-Kapazitäten im Millionen-Bereich). Verhindert
  -- den selbstverstärkenden SHED-Loop: Node liefert kurz 0 -> winziges Ziel
  -- berechnet -> Node als "Überschuss" markiert -> bleibt abgeschaltet.
  if learned_capacity_total > 0 then return learned_capacity_total, "learned-capacity" end
  if runtime.state.power_target and runtime.state.power_target > 0 then return runtime.state.power_target, "previous-target" end
  local setpoints = runtime.config.rt_setpoints or {}
  local per_node_capacity = math.max(1, number_or(setpoints.power_per_node_capacity, 3000))
  local capacity_nodes = math.max(available_count, rt_count)
  if capacity_nodes > 0 then
    return capacity_nodes * per_node_capacity, "capacity-fallback"
  end
  return 0, "unavailable"
end

function M.apply_profile(runtime, name)
  if runtime.state.rt_global_off_hold then
    runtime.log("Ignoring profile change while RT-OFF hold is active", "WARN")
    return
  end
  local profile = runtime.libs.profiles[name]
  if not profile then return end
  runtime.state.active_profile = name
  runtime.refs.sequencer.ramp_profile = profile.ramp or runtime.refs.sequencer.ramp_profile
  runtime.log(("Profile applied: %s (target_factor=%s, ramp=%s)"):format(tostring(name), tostring(profile.target), tostring(runtime.refs.sequencer.ramp_profile)), "INFO")
  local base, base_source = M.estimate_base_power(runtime)
  if base > 0 then
    runtime.state.power_target = base * profile.target
    runtime.log(("Power target recalculated from profile %s: base=%.2f source=%s -> target=%.2f"):format(tostring(name), base, tostring(base_source or "unknown"), runtime.state.power_target), "INFO")
    for _, node in pairs(runtime.state.nodes) do
      if node.role == runtime.libs.constants.roles.RT_NODE then
        runtime.mark_rt_sync_dirty(node, "profile_change")
      end
    end
    runtime.flush_rt_sync_queue({ force = true })
  else
    runtime.log(("Profile %s applied but base power is unavailable (rt_count=0 or estimate failed); target unchanged at %.2f"):format(tostring(name), tonumber(runtime.state.power_target) or 0), "WARN")
  end
end

function M.set_rt_global_hold(runtime, enabled)
  local next_value = enabled == true
  if runtime.state.rt_global_off_hold == next_value then return end
  runtime.state.rt_global_off_hold = next_value
  runtime.log("RT global hold " .. (runtime.state.rt_global_off_hold and "ENABLED (0%)" or "DISABLED (normal control)"), "WARN")
  for _, node in pairs(runtime.state.nodes) do
    if node.role == runtime.libs.constants.roles.RT_NODE then
      runtime.mark_rt_sync_dirty(node, "global_hold_toggle")
    end
  end
  runtime.flush_rt_sync_queue({ force = true })
end

function M.sample_trends(runtime)
  local now = os.epoch("utc")
  if now - runtime.state.last_trend_sample < 1000 then return end
  runtime.state.last_trend_sample = now
  local power, stored, capacity, water_total = 0, 0, 0, 0
  for _, node in pairs(runtime.state.nodes) do
    if node.role == runtime.libs.constants.roles.RT_NODE then
      power = power + (number_or(node.actual_output, nil) or number_or(node.power_actual, nil) or number_or(node.output, 0))  -- actual_output kanonisch
    elseif node.role == runtime.libs.constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
    elseif node.role == runtime.libs.constants.roles.WATER_NODE then
      water_total = node.total_water or water_total
    end
  end
  local energy_pct = capacity > 0 and (stored / capacity) * 100 or 0
  runtime.refs.trends:push("power", power)
  if runtime.refs.trends:push("energy", energy_pct) then
    local trend_values = runtime.refs.trends:values("energy")
    runtime.state.trend_cache.energy = trend_values
    if #trend_values >= 2 then
      local last = trend_values[#trend_values]
      local prev = trend_values[#trend_values - 1]
      if last > prev + 0.5 then runtime.state.trend_cache.energy_arrow = "↑"
      elseif last < prev - 0.5 then runtime.state.trend_cache.energy_arrow = "↓"
      else runtime.state.trend_cache.energy_arrow = "→" end
    else runtime.state.trend_cache.energy_arrow = "→" end
  end
  runtime.refs.trends:push("water", water_total)
  if runtime.state.auto_profile then
    -- Fix: power_target=0 beim Start (noch kein Profilwechsel ausgelöst) ist ein
    -- Sonderfall — sonst bleibt assigned=0% für immer obwohl auto_profile aktiv ist.
    -- Erzwingt einen einmaligen apply_profile()-Aufruf auch ohne Profilwechsel.
    if (not runtime.state.power_target or runtime.state.power_target <= 0) then
      M.apply_profile(runtime, runtime.state.active_profile or "BASELOAD")
    elseif energy_pct > 90 and runtime.state.active_profile ~= "IDLE" then
      M.apply_profile(runtime, "IDLE")
    elseif energy_pct < 30 and runtime.state.active_profile ~= "PEAK" then
      M.apply_profile(runtime, "PEAK")
    end
  end
end

return M
