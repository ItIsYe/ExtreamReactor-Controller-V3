local M = {}

local function normalize_status(raw)
  local s = tostring(raw or "OFFLINE"):upper()
  if s == "CRITICAL" then return "EMERGENCY" end
  if s == "WARN" then return "WARNING" end
  if s == "INFO" then return "LIMITED" end
  return s
end

function M.new(opts)
  local c = opts
  local function to_number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then
      local n = tonumber(value)
      if n then return n end
      local left, right = value:match("^%s*([%+%-]?[%d%.]+)%s*/%s*([%+%-]?[%d%.]+)%s*$")
      if left and right then
        local a, b = tonumber(left), tonumber(right)
        if a and b then return a, b end
      end
    end
  end
  local function pick_number(...)
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      local n = to_number(v)
      if n ~= nil then return n end
    end
    return 0
  end
  local function first_nonempty(...)
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      if v ~= nil and tostring(v) ~= "" and tostring(v) ~= "-" then return v end
    end
  end
  local function profile_target_factor(profile_name)
    local key = tostring(profile_name or "BASELOAD"):upper()
    if key == "PEAK" then return 1.0 end
    if key == "IDLE" then return 0.2 end
    return 0.6
  end
  local function normalize_assignment(state)
    local map = {
      active = "ASSIGNED", startup = "ASSIGNED", standby = "ASSIGNED",
      shutdown = "ASSIGNED", shed = "ASSIGNED", unavailable = "UNAVAILABLE",
      master = "ASSIGNED", assigned = "ASSIGNED", unassigned = "UNASSIGNED"
    }
    local raw = tostring(state or "UNASSIGNED")
    local key = raw:lower()
    return map[key] or raw:upper()
  end
  local function infer_assignment_state(rt_node, node)
    -- Fix (2026-06-30): node.assignment_state (vom Master-RT-Sync in
    -- rt_sync.lua gesetzt, stabil über STATUS-Ticks hinweg) muss VOR
    -- rt_node.assignment_state geprüft werden. Grund: rt_node ist bei
    -- vorhandenem node.rt eine direkte Referenz auf node.rt — und
    -- message_handlers.populate_rt_status() ersetzt node.rt bei JEDEM
    -- STATUS-Tick komplett durch das frische payload.rt (node.rt = payload.rt
    -- or node.rt or {}), statt es zu mergen. Ein zuvor vom UI gesetztes
    -- rt_node.assignment_state="ASSIGNED" (siehe normalize_rt_display(), das
    -- direkt in rt_node mutiert) geht dadurch bei der naechsten STATUS-
    -- Nachricht sofort wieder verloren — RT selbst sendet ohnehin nie ein
    -- eigenes assignment_state-Feld im Payload. Je nach Timing zwischen
    -- STATUS-Empfang und naechstem UI-Render zeigte das zufaellig fuer manche
    -- Nodes UNASSIGNED, fuer andere (gleicher Code!) ASSIGNED — reines
    -- Zufallstiming, kein Unterschied im Verhalten der RT-Node selbst.
    local raw = first_nonempty(
      node.assignment_state,
      rt_node.assignment_state,
      node.bindings_state,
      node.bindings and node.bindings.assignment_state,
      node.last_setpoints and node.last_setpoints.assignment_state
    )
    local normalized = normalize_assignment(raw or "UNASSIGNED")
    local has_master_binding = (node.bindings and (node.bindings.master_id or node.bindings.assigned)) or
      (rt_node.master_id ~= nil) or (rt_node.assignment_id ~= nil)
    if normalized == "UNASSIGNED" and has_master_binding then
      return "ASSIGNED"
    end
    return normalized
  end
  local function normalize_control_source(raw, assignment)
    local v = tostring(raw or ""):upper()
    if v == "MASTER" or v == "LOCAL" then return v end
    if v == "REMOTE" or v == "ASSIGNED" then return "MASTER" end
    if v == "FALLBACK" or v == "AUTONOM" then return "LOCAL" end
    if assignment == "ASSIGNED" then return "MASTER" end
    return "LOCAL"
  end
  local function normalize_rt_display(rt_node)
    local assign = normalize_assignment(rt_node.assignment_state)
    local reason = tostring(rt_node.assignment_reason or "-")
    local control = normalize_control_source(rt_node.control_source, assign)
    if assign == "ASSIGNED" then
      rt_node.display_mode = (control == "MASTER") and "Master-gefuehrt" or "Lokale Steuerung trotz Master-Zuordnung"
    elseif assign == "UNAVAILABLE" then
      rt_node.display_mode = "Master nicht verfuegbar"
      control = "LOCAL"
    else
      rt_node.display_mode = (control == "MASTER") and "Master-Steuerung ohne klare Zuordnung" or "Lokal/Fallback (nicht zugeordnet)"
      if reason == "-" and tostring(rt_node.node_mode or rt_node.mode or "-"):upper() == "AUTONOM" then
        reason = "Node ohne Master-Zuordnung"
      end
    end
    rt_node.assignment_state = assign
    rt_node.assignment_reason = reason
    rt_node.control_source = control
    return rt_node
  end


  local function normalize_assignment_reason(reason, assignment, node_mode, stale)
    local text = tostring(reason or "-")
    if text ~= "" and text ~= "-" then return text end
    if stale then return "Keine frischen Node-Daten" end
    local mode = tostring(node_mode or "-"):upper()
    if assignment == "ASSIGNED" then return "Master-Zuordnung aktiv" end
    if assignment == "UNAVAILABLE" then return "Master fuer Zuordnung nicht verfuegbar" end
    if mode == "AUTONOM" then return "Autonom ohne Master-Zuordnung" end
    return "Master-Zuordnung offen"
  end

  local function matrix_rows_from_payload(e)
    local out = {}
    local function collect(src)
      if type(src) ~= "table" then return end
      if #src > 0 then
        for _, row in ipairs(src) do out[#out + 1] = row end
        return
      end
      for key, row in pairs(src) do
        if type(row) == "table" then
          local copy = {}
          for k, v in pairs(row) do copy[k] = v end
          copy.id = first_nonempty(copy.id, copy.label, copy.name, key)
          out[#out + 1] = copy
        end
      end
    end
    collect(e.matrices)
    collect(e.matrix_rows)
    collect(e.matrix_data)
    return out
  end

  local function build_models()
    local now = os.epoch('utc')
    local counts = c.alert_service and c.alert_service:get_counts() or { INFO = 0, WARN = 0, CRITICAL = 0 }
    local top = c.alert_service and c.alert_service:get_top_critical(3) or {}
    local summary = c.alert_service and c.alert_service:get_summary() or 'Keine aktiven Meldungen'

    local overview = { system_status = 'OK', profile_list = { 'BASELOAD', 'PEAK', 'IDLE' }, active_profile = c.calc.get_active_profile and c.calc.get_active_profile() or c.state.active_profile, auto_profile = c.calc.get_auto_profile and c.calc.get_auto_profile() or c.state.auto_profile, rt_global_off_hold = c.calc.get_rt_global_off_hold and c.calc.get_rt_global_off_hold() or c.state.rt_global_off_hold, power_target = c.calc.get_power_target and c.calc.get_power_target() or c.state.power_target, nodes = {}, alert_rows = {}, alert_summary = summary, alert_counts = counts, energy_overview = { percent = 0, status = 'OFFLINE', trend = 'Trend stabil' }, rt_online = 0, power_actual = 0, clock_label = '', ops_hints = {}, peer_summary = 'Peers live=0 stale=0 rt=0 energy-matrix=0 src=0', rt_summary = 'RT active=0 startup=0 shutdown=0 stale=0 assigned=0 unassigned=0 unavailable=0 master=0 local=0', controls_summary = 'Profile=- | AUTO=AUS | RT-HOLD=AUS', nodes_total = 0, nodes_live = 0, nodes_stale = 0, system_status_line = "Normalbetrieb", node_status_line = "Nodes live=0 stale=0", control_status_line = "AUTO aus | RT-Hold aus" }
    if (counts.CRITICAL or 0) > 0 then overview.system_status = 'EMERGENCY' elseif (counts.WARN or 0) > 0 then overview.system_status = 'WARNING' end
    for i, a in ipairs(top) do if i > 4 then break end overview.alert_rows[#overview.alert_rows+1] = { title = tostring(a.title or a.code or 'Alert'), text = tostring(a.message or a.detail or 'Keine Details'), status = normalize_status(a.severity or 'WARNING') } end

    local rt = { rt_nodes = {}, queue = c.sequencer.queue or {}, ramp_profile = c.sequencer.ramp_profile, sequence_state = c.sequencer.state, rt_global_off_hold = overview.rt_global_off_hold, rt_active = 0, rt_startup = 0, rt_shutdown = 0, assigned = 0, unassigned = 0, unavailable = 0, local_control = 0, master_control = 0, assignment_state = 'UNASSIGNED', assignment_reason = '-', control_source = 'LOCAL', display_mode = 'RT-Fleet aktiv', fleet_summary = '-', queue_summary = '-' }
    local energy = { stored = 0, capacity = 0, input = 0, output = 0, matrices = {}, resources = {}, support_nodes = {}, status = 'OFFLINE', aggregate_percent = 0, mode = '-', energy_summary = 'Energy 0.0% | Stored 0.0/0.0 | In 0.0 Out 0.0 | Mode - | Matrices 0', matrix_count = 0, matrix_sources = 0, support_online = 0, support_stale = 0, matrix_only = false }

    -- Fix: jede Node-Iteration einzeln pcall-geschützt. Vorher: ein Fehler
    -- bei der Verarbeitung EINER Node (egal ob RT/Energy/Fuel/etc.) crashte
    -- den ganzen Loop und damit ALLE 3 Models (overview/rt/energy)
    -- gleichzeitig — auch wenn nur eine einzelne Node kaputte/unerwartete
    -- Payload-Felder hatte (klassisches Boot-Race-Condition-Szenario, siehe
    -- v99 build_models_safe()-Fix). Eine komplette Aufteilung in 3 getrennte
    -- Funktionen würde den gemeinsamen Node-Loop verdreifachen (die 3 Models
    -- werden bewusst in EINEM Durchlauf gemeinsam befüllt) — das wäre ein
    -- größerer strukturelles Rewrite. Pro-Node-pcall erreicht das eigentliche
    -- Ziel (Fehlerisolierung) mit minimalem Risiko: eine kaputte Node wird
    -- übersprungen und geloggt, alle anderen Nodes tragen weiter normal zu
    -- allen 3 Models bei.
    local node_errors = 0
    for _, node in pairs(c.nodes or {}) do
      local ok_node, node_err = pcall(function()
      local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((now - node.last_seen) / 1000)) or -1)
      local stale = age >= 0 and age > 15
      local freshness_note = stale and 'stale' or 'live'
      local node_status = stale and 'OFFLINE' or normalize_status(node.status or 'OFFLINE')
      local node_mode = node.mode or (node.rt and node.rt.mode) or '-'
      overview.nodes[#overview.nodes+1] = { id = node.id, role = node.role or '-', status = node_status, last_seen_age = age, mode = node_mode, note = node.bindings_summary or node.note or (node.rt and node.rt.assignment_reason) or freshness_note, freshness = freshness_note }
      overview.nodes_total = (overview.nodes_total or 0) + 1
      if stale then overview.nodes_stale = (overview.nodes_stale or 0) + 1 else overview.nodes_live = (overview.nodes_live or 0) + 1 end
      if node.role == c.constants.roles.RT_NODE then
        if not stale then overview.rt_online = overview.rt_online + 1 end
        local rt_node = node.rt or { status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }
        rt_node.id = first_nonempty(rt_node.id, node.id, node.node_id, node.sender_id, "UNKNOWN")
        rt_node.status = stale and 'OFFLINE' or normalize_status(rt_node.status or node.status)
        rt_node.last_seen_age = age
        rt_node.freshness = freshness_note
        rt_node.node_status = node_status
        rt_node.node_mode = first_nonempty(rt_node.node_mode, rt_node.mode, node_mode, "-")
        rt_node.mode = rt_node.node_mode
        rt_node.assignment_state = infer_assignment_state(rt_node, node)
        -- Fix (2026-06-30): dieselbe Sticky-Falle wie bei assignment_state
        -- (siehe infer_assignment_state()) — rt_node ist bei vorhandenem
        -- node.rt eine direkte Referenz darauf. normalize_rt_display()
        -- schreibt control_source DIREKT in rt_node (Zeile ~110:
        -- rt_node.control_source = control). Beim naechsten Aufruf hier
        -- gewann "rt_node.control_source or ..." dann IMMER den zuvor
        -- (ggf. falsch auf "LOCAL" normalisierten) Wert, noch bevor der
        -- stabile, vom Master-RT-Sync gesetzte node.control_source ueberhaupt
        -- geprueft wurde — node.control_source kam nie mehr zum Zug, sobald
        -- rt_node.control_source einmal "LOCAL" geworden war. Jetzt:
        -- node.control_source zuerst pruefen.
        rt_node.control_source = node.control_source or (node.last_setpoints and node.last_setpoints.control_source) or (node.bindings and node.bindings.control_source) or rt_node.control_source
        -- Fix (2026-06-30): "Soll"-Anzeige im UI zeigte dauerhaft 0, weil
        -- rt_target() (rt_dashboard.lua) auf rt.power_target zurueckfiel —
        -- ein Feld, das RT seit dem SCADA-Rewrite nie mehr sendet (RT bekommt
        -- nur noch power_target_percent, berechnet seinen Output selbst).
        -- node.assigned_power (jetzt von rt_sync.lua persistiert) ist der
        -- tatsaechliche, vom Master berechnete RF/t-Sollwert pro Node.
        rt_node.target = node.assigned_power or rt_node.target
        rt_node.assignment_reason = normalize_assignment_reason(
          rt_node.assignment_reason or node.assignment_reason or (node.last_setpoints and node.last_setpoints.assignment_reason) or node.bindings_summary,
          rt_node.assignment_state,
          rt_node.node_mode,
          stale
        )
        -- Fix (2026-06-30): defensiv gegen Tabellenwerte absichern — eine
        -- der Quellen hier (rt_node.queue_state, node.queue_state, node.state)
        -- lieferte in der Praxis vereinzelt eine Tabelle statt eines Strings,
        -- was im UI als "table: 0x..." auftauchte (siehe rt_dashboard.lua
        -- safe_text()). Ursache nicht abschliessend geklärt; hier zusaetzlich
        -- an der Quelle abgesichert, nicht nur im Rendering.
        local function string_or_nil(v)
          if type(v) == "string" or type(v) == "number" then return tostring(v) end
          return nil
        end
        rt_node.queue_state = string_or_nil(rt_node.queue_state) or string_or_nil(node.queue_state) or string_or_nil(node.state) or "idle"
        rt_node.queue_step = string_or_nil(rt_node.queue_step) or string_or_nil(node.queue_step) or string_or_nil(node.last_command_result and node.last_command_result.transition) or "-"
        -- Capacity-Learning Status aus dem Node-Payload lesen
        local rt_data = node.rt or {}
        rt_node.capacity_ready          = rt_data.capacity_ready == true or node.capacity_ready == true
        rt_node.capacity_max            = pick_number(rt_data.capacity_max, node.capacity_max, 0)
        rt_node.capacity_stable_samples = rt_data.capacity_stable_samples or 0
        rt_node.capacity_stable_turbines= rt_data.capacity_stable_turbines or 0
        rt_node.capacity_total_turbines = rt_data.capacity_total_turbines or 0
        rt_node.capacity_source         = rt_data.capacity_source or "UNKNOWN"
        -- Learning-Meldung für die UI aufbauen
        if not rt_node.capacity_ready then
          rt_node.learning_note = string.format(
            "LEARNING %d/%d Turbinen stabil (%d Samples)",
            rt_node.capacity_stable_turbines,
            rt_node.capacity_total_turbines,
            rt_node.capacity_stable_samples
          )
          rt.rt_learning = (rt.rt_learning or 0) + 1
        else
          rt_node.learning_note = string.format(
            "READY %.0f RF/t", rt_node.capacity_max
          )
        end
        rt_node = normalize_rt_display(rt_node)
        if rt_node.assignment_state == "ASSIGNED" then
          rt.assigned = (rt.assigned or 0) + 1
        elseif rt_node.assignment_state == "UNAVAILABLE" then
          rt.unavailable = (rt.unavailable or 0) + 1
        else
          rt.unassigned = (rt.unassigned or 0) + 1
        end
        if rt_node.control_source == "MASTER" then rt.master_control = (rt.master_control or 0) + 1 else rt.local_control = (rt.local_control or 0) + 1 end
        if stale then rt.rt_stale = (rt.rt_stale or 0) + 1 end
        rt.rt_nodes[#rt.rt_nodes+1] = rt_node
        overview.power_actual = overview.power_actual + pick_number(rt_node.actual_output, rt_node.output, node.output, node.actual_output, 0)
        local state = tostring(rt_node.state or '')
        if state == 'RUNNING' then rt.rt_active = rt.rt_active + 1 elseif state == 'STARTUP' then rt.rt_startup = rt.rt_startup + 1 elseif state == 'SHUTDOWN' then rt.rt_shutdown = rt.rt_shutdown + 1 end
      elseif node.role == c.constants.roles.ENERGY_NODE then
        local e = (type(node.energy) == "table" and node.energy) or (type(node.payload) == "table" and node.payload.energy) or node.payload or node
        local total = (type(e.total) == "table" and e.total) or {}
        energy.stored = energy.stored + pick_number(e.aggregate_stored, e.stored, e.matrix_energy, total.stored)
        energy.capacity = energy.capacity + pick_number(e.aggregate_capacity, e.capacity, e.matrix_capacity, total.capacity)
        energy.input = energy.input + pick_number(e.aggregate_input, e.input, e.matrix_in, total.input)
        energy.output = energy.output + pick_number(e.aggregate_output, e.output, e.matrix_out, total.output)
        energy.mode = first_nonempty(e.mode, e.operating_mode, energy.mode, "-")
        energy.support_nodes[#energy.support_nodes + 1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or normalize_status(node.status or 'OK'), last_seen_age = age, note = e.mode or e.note or node.bindings_summary or "Energy-Node", freshness = freshness_note }
        if stale then energy.support_stale = (energy.support_stale or 0) + 1 else energy.support_online = (energy.support_online or 0) + 1 end
        local matrix_only = (e.matrix_only == true) or (e.kind == "matrix_only") or (e.payload_kind == "matrix_only")
        energy.matrix_only = energy.matrix_only or matrix_only
        local matrices = matrix_rows_from_payload(e)
        energy.matrix_sources = (energy.matrix_sources or 0) + (#matrices > 0 and 1 or 0)
        for _, m in ipairs(matrices) do
          local copy = {}
          for k,v in pairs(m) do copy[k]=v end
          copy.last_seen_age = age
          copy.status = stale and 'OFFLINE' or normalize_status(copy.status or node.status or 'OK')
          copy.percent = pick_number(copy.percent, copy.fill, copy.level, copy.aggregate_percent, 0)
          if copy.percent > 0 and copy.percent <= 1 then copy.percent = copy.percent * 100 end
          copy.input = pick_number(copy.input, copy.inflow, copy.rate_in, 0)
          copy.output = pick_number(copy.output, copy.outflow, copy.rate_out, 0)
          copy.id = first_nonempty(copy.id, copy.label, copy.name, node.id .. "-matrix")
          energy.matrices[#energy.matrices+1] = copy
        end
      else
        energy.support_nodes[#energy.support_nodes+1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or normalize_status(node.status or 'OFFLINE'), last_seen_age = age, note = node.bindings_summary or node.note or '', freshness = freshness_note }
        if stale then energy.support_stale = (energy.support_stale or 0) + 1 else energy.support_online = (energy.support_online or 0) + 1 end
      end
      if node.role == c.constants.roles.FUEL_NODE then energy.resources.fuel_total = (energy.resources.fuel_total or 0) + ((node.fuel and node.fuel.amount) or 0); energy.resources.fuel_sources = (energy.resources.fuel_sources or 0) + 1 end
      if node.role == c.constants.roles.WATER_NODE then energy.resources.water_total = (energy.resources.water_total or 0) + ((node.water and node.water.total) or 0) end
      if node.role == c.constants.roles.REPROCESSOR_NODE then energy.resources.reprocessing_state = (node.reprocessor and (node.reprocessor.state or node.reprocessor.mode)) or '-' end
      end)
      if not ok_node then
        node_errors = node_errors + 1
        if c.log then
          c.log("build_models: error processing node " .. tostring(node and node.id or "?") .. ": " .. tostring(node_err), "ERROR")
        end
      end
    end
    if node_errors > 0 then
      overview.ops_hints[#overview.ops_hints + 1] = string.format("%d Node(s) bei der Modell-Berechnung uebersprungen (siehe Logs)", node_errors)
    end
    if (overview.power_target or 0) <= 0 and (overview.power_actual or 0) > 0 then
      overview.power_target = overview.power_actual * profile_target_factor(overview.active_profile)
    end
    table.sort(overview.nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    table.sort(rt.rt_nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    if #rt.rt_nodes == 0 then
      rt.rt_nodes[1] = { id = "NO-RT", status = "OFFLINE", state = "IDLE", node_mode = "-", assignment_state = "UNASSIGNED", assignment_reason = "Keine RT-Node-Daten im Tick", control_source = "LOCAL", display_mode = "RT-Hauptansicht aktiv", queue_state = "idle", queue_step = "-", freshness = "n/a", node_status = "OFFLINE" }
    end
    table.sort(energy.support_nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    if #energy.support_nodes == 0 then
      energy.support_nodes[1] = { id = "NO-SUPPORT", role = "-", status = "OFFLINE", last_seen_age = -1, note = "Keine Support-Nodes sichtbar", freshness = "n/a" }
    end
    local pct = energy.capacity > 0 and (energy.stored / energy.capacity) * 100 or 0
    energy.aggregate_percent = pct
    energy.status = pct < 15 and 'EMERGENCY' or (pct < 30 and 'WARNING' or 'OK')
    overview.energy_overview = { percent = pct, status = energy.status, trend = (pct > 70 and 'Trend stabil') or (pct > 35 and 'Trend sinkt') or 'Trend kritisch' }
    overview.nodes_total = overview.nodes_total or 0
    overview.nodes_live = overview.nodes_live or 0
    overview.nodes_stale = overview.nodes_stale or 0
    energy.matrix_count = #energy.matrices
    overview.peer_summary = string.format('Peers live=%d stale=%d rt=%d energy-matrix=%d src=%d', overview.nodes_live, overview.nodes_stale, overview.rt_online or 0, energy.matrix_count or 0, energy.matrix_sources or 0)
    -- Learning-Meldung in rt_summary einbauen
    local learning_count = rt.rt_learning or 0
    local learning_hint = learning_count > 0
      and string.format(" | LEARNING: %d Node(s) lernen noch ein", learning_count)
      or ""
    overview.rt_summary = string.format(
      "RT active=%d startup=%d shutdown=%d stale=%d assigned=%d unassigned=%d unavailable=%d master=%d local=%d%s",
      rt.rt_active or 0, rt.rt_startup or 0, rt.rt_shutdown or 0, rt.rt_stale or 0,
      rt.assigned or 0, rt.unassigned or 0, rt.unavailable or 0,
      rt.master_control or 0, rt.local_control or 0,
      learning_hint
    )
    overview.energy_hint = string.format("Energy %.1f%% | Stored %.1f/%.1f | In %.1f Out %.1f | Mode %s | Matrices %d", energy.aggregate_percent or 0, energy.stored or 0, energy.capacity or 0, energy.input or 0, energy.output or 0, tostring(energy.mode or "-"), energy.matrix_count or 0)
    energy.energy_summary = overview.energy_hint
    overview.ops_hints[#overview.ops_hints + 1] = (overview.nodes_stale or 0) > 0 and "Stale Nodes erkannt: Kommunikationslage pruefen" or "Alle Nodes liefern frische Daten"
    overview.ops_hints[#overview.ops_hints + 1] = (energy.matrix_count or 0) > 0 and "Matrixdaten live im Master-Modell" or "Keine Matrixzeilen gemeldet"
    overview.ops_hints[#overview.ops_hints + 1] = (energy.matrix_only and "Energy meldet Matrix-Only Betrieb") or "Energy meldet kombinierte Storage/Matrix-Daten"
    overview.ops_hints[#overview.ops_hints + 1] = (rt.rt_stale or 0) > 0 and "RT stale: Zuordnung/Netz pruefen" or "RT-Sync ueberwiegend stabil"
    overview.ops_hints[#overview.ops_hints + 1] = ((rt.unassigned or 0) > 0) and "RT hat unzugeordnete Nodes: Assignment/Control pruefen" or "RT-Zuordnung vollständig"
    overview.controls_summary = string.format("Profile=%s | AUTO=%s | RT-HOLD=%s", tostring(overview.active_profile or '-'), tostring(overview.auto_profile and 'AN' or 'AUS'), tostring(overview.rt_global_off_hold and 'AN' or 'AUS'))
    overview.system_status_line = string.format("Status %s | Alerts C:%d W:%d I:%d", tostring(overview.system_status or "OK"), counts.CRITICAL or 0, counts.WARN or 0, counts.INFO or 0)
    overview.node_status_line = string.format("Nodes total=%d live=%d stale=%d | RT online=%d", overview.nodes_total or 0, overview.nodes_live or 0, overview.nodes_stale or 0, overview.rt_online or 0)
    overview.control_status_line = string.format("Control %s | AUTO %s | RT-HOLD %s", tostring(overview.active_profile or "-"), overview.auto_profile and "AN" or "AUS", overview.rt_global_off_hold and "AN" or "AUS")
    rt.assignment_state = ((rt.unassigned or 0) == 0 and (rt.assigned or 0) > 0) and 'ASSIGNED' or (((rt.unavailable or 0) > 0 and (rt.assigned or 0) == 0) and 'UNAVAILABLE' or 'MIXED')
    if #(rt.rt_nodes or {}) == 0 then
      rt.assignment_state = 'UNASSIGNED'
      rt.assignment_reason = 'Keine RT-Node-Daten im Tick'
    else
      rt.assignment_reason = ((rt.unassigned or 0) > 0) and 'Teilweise unzugeordnet' or (((rt.unavailable or 0) > 0) and 'Master teilweise nicht verfuegbar' or 'Master-Zuordnung stabil')
    end
    rt.control_source = ((rt.master_control or 0) >= (rt.local_control or 0)) and 'MASTER' or 'LOCAL'
    rt.display_mode = 'Node/Assignment/Control getrennt'
    rt.fleet_summary = string.format("RT nodes=%d active=%d startup=%d shutdown=%d stale=%d", #(rt.rt_nodes or {}), rt.rt_active or 0, rt.rt_startup or 0, rt.rt_shutdown or 0, rt.rt_stale or 0)
    rt.queue_summary = string.format("Queue=%d ramp=%s seq=%s", #(rt.queue or {}), tostring(rt.ramp_profile or '-'), tostring(rt.sequence_state or '-'))
    energy.resource_summary = string.format("Fuel %.1f | Water %.1f | Reproc %s", energy.resources.fuel_total or 0, energy.resources.water_total or 0, tostring(energy.resources.reprocessing_state or "-"))
    overview.clock_label = os.date('!%H:%M UTC')
    rt.rt_global_off_hold = overview.rt_global_off_hold

    -- Fix (2026-06-30): "alerts"-Model fehlte in data_map komplett — weder die
    -- "Alerts"-View noch der AUX-Monitor-Badge (multiview.lua) bekamen je die
    -- echten alert_service-Daten (active alerts mit severity/title/message),
    -- nur die manuell geloggten add_alarm()-Events landeten auf dem "Logs"-
    -- View. Folge: AUX-Monitor blieb dauerhaft grün/"Keine aktiven Alarme"
    -- trotz aktiver CRITICAL/WARN-Alerts aus dem alert_service. Hier wird das
    -- vollstaendige Model gebaut, das alerts.lua's render() erwartet
    -- (model.counts, model.summary, model.active).
    local alerts_active = c.alert_service and c.alert_service:get_active() or {}
    local alerts_history = c.alert_service and c.alert_service:get_history() or {}
    local alert_svc = c.alert_service
    local function on_ack(id)
      if alert_svc and type(alert_svc.ack) == "function" then
        alert_svc:ack(id)
      end
    end
    local alerts_model = {
      counts = counts,
      summary = summary,
      active = alerts_active,
      history = alerts_history,
      mutes = (c.alert_service and c.alert_service.state and c.alert_service.state.mutes) or { rules = {}, nodes = {} },
      now_ms = now,
      config = c.config or {},
      on_ack = on_ack,
    }

    -- Fix (2026-06-30): "alarms"-Model ("Logs"-View, AUX-Monitor) zeigte
    -- bisher NUR die manuell via add_alarm() geloggten Events (Startup
    -- rejected, Emergency stop active, ...), niemals die automatisch vom
    -- alert_service erkannten Bedingungen (z.B. niedriger Energiespeicher-
    -- stand). Jetzt werden beide Quellen kombiniert: aktive alert_service-
    -- Alerts zuerst (sie sind die dringendsten), danach die manuellen Events.
    -- Severity wird von CRITICAL/WARN/INFO auf das von alarms.lua erwartete
    -- Schema EMERGENCY/WARNING/OK gemappt.
    local function map_alert_severity(sev)
      local s = tostring(sev or ""):upper()
      if s == "CRITICAL" then return "EMERGENCY" end
      if s == "WARN" or s == "WARNING" then return "WARNING" end
      return "LIMITED"
    end
    local combined_alarms = {}
    for _, a in ipairs(alerts_active) do
      combined_alarms[#combined_alarms + 1] = {
        severity = map_alert_severity(a.severity),
        message = tostring(a.title or a.message or a.code or "Alert"),
        detail = tostring(a.message or a.detail or a.source or ""),
        timestamp = a.timestamp or overview.clock_label,
      }
    end
    for _, a in ipairs(c.alarms or {}) do
      combined_alarms[#combined_alarms + 1] = {
        severity = a.severity,
        message = a.message,
        detail = a.sender_id,
        timestamp = a.timestamp,
      }
    end
    local alarms_model = {
      active = alerts_active,
      header_blink = (counts.CRITICAL or 0) > 0,
      on_ack = on_ack,
    }

    return { overview = overview, rt = rt, energy = energy, resources = {}, alerts = alerts_model, alarms = alarms_model }
  end

  -- Fix: build_models() lief völlig ungeschützt. Ein Fehler dort (z.B. weil
  -- eine gerade erst registrierte Node noch unvollständige/ungewöhnlich
  -- geformte Payload-Felder hat — klassisches Race-Condition-Szenario beim
  -- Boot, wenn der Master schneller online ist als z.B. eine Energy-Node)
  -- crashte den GESAMTEN draw()-Aufruf, BEVOR das pcall() in multiview.lua
  -- greifen konnte (das schützt nur render(), nicht den Model-Aufbau davor).
  -- Folge: die UI blieb in einem kaputten Zustand hängen, ohne dass die
  -- bestehende RENDER ERROR/VIEW ERROR Anzeige je zum Zug kam — nur ein
  -- manueller Reboot half, weil dann genug Zeit für vollständige Node-Daten
  -- verging. Jetzt: build_models() ist selbst abgesichert; bei Fehlschlag
  -- werden sichere leere Default-Modelle verwendet und der Fehler geloggt,
  -- sodass die UI weiterläuft statt hängen zu bleiben.
  local function build_models_safe()
    local ok, models = pcall(build_models)
    if ok and type(models) == "table" then return models end
    if c.log then
      c.log("build_models() failed, using safe defaults: " .. tostring(models), "ERROR")
    end
    return {
      overview = { system_status = "WARNING", profile_list = { "BASELOAD", "PEAK", "IDLE" }, nodes = {}, alert_rows = {}, alert_summary = "Modellfehler — siehe Logs", alert_counts = { INFO = 0, WARN = 1, CRITICAL = 0 }, energy_overview = { percent = 0, status = "OFFLINE", trend = "Trend stabil" }, rt_online = 0, power_actual = 0, clock_label = os.date("!%H:%M UTC"), ops_hints = { "Modellaufbau fehlgeschlagen, Daten folgen in Kürze" }, peer_summary = "Peers live=0 stale=0 rt=0 energy-matrix=0 src=0", rt_summary = "RT active=0 startup=0 shutdown=0 stale=0 assigned=0 unassigned=0 unavailable=0 master=0 local=0", controls_summary = "Profile=- | AUTO=AUS | RT-HOLD=AUS", nodes_total = 0, nodes_live = 0, nodes_stale = 0, system_status_line = "Initialisierung...", node_status_line = "Nodes live=0 stale=0", control_status_line = "AUTO aus | RT-Hold aus" },
      rt = { rt_nodes = {}, queue = {}, rt_active = 0, rt_startup = 0, rt_shutdown = 0, assigned = 0, unassigned = 0, unavailable = 0, local_control = 0, master_control = 0, assignment_state = "UNASSIGNED", assignment_reason = "-", control_source = "LOCAL", display_mode = "RT-Fleet aktiv", fleet_summary = "-", queue_summary = "-" },
      energy = { stored = 0, capacity = 0, input = 0, output = 0, matrices = {}, resources = {}, support_nodes = {}, status = "OFFLINE", aggregate_percent = 0, mode = "-", energy_summary = "Energy 0.0% | Stored 0.0/0.0 | In 0.0 Out 0.0 | Mode - | Matrices 0", matrix_count = 0, matrix_sources = 0, support_online = 0, support_stale = 0, matrix_only = false },
      resources = {},
      alerts = { counts = { INFO = 0, WARN = 0, CRITICAL = 0 }, summary = "Keine aktiven Meldungen", active = {}, history = {}, mutes = { rules = {}, nodes = {} }, now_ms = os.epoch('utc'), config = {} },
      alarms = { alarms = {}, header_blink = false }
    }
  end

  local controller = {}
  controller.draw = function()
      local models = build_models_safe()
      controller._last_models = models
      local monitors = c.state.monitor_cache.list or {}
      local rendered = c.view_manager:render(monitors, models) or {}
      c.state.last_ui_model_stats = {
        overview_nodes = #(models.overview and models.overview.nodes or {}),
        rt_nodes = #(models.rt and models.rt.rt_nodes or {}),
        support_nodes = #(models.energy and models.energy.support_nodes or {}),
        matrices = #(models.energy and models.energy.matrices or {})
      }
      if models.overview and models.overview.ui_errors and c.log then
        for _, msg in ipairs(models.overview.ui_errors) do
          c.log("Overview section fallback triggered: " .. tostring(msg), "ERROR")
        end
      end
      local ov_meta = models.overview and models.overview._overview_render_meta
      c.state.last_overview_render_meta = ov_meta
      if ov_meta and c.log then
        if ov_meta.cache_unchanged then
          c.log("Overview render executed with unchanged model (cache bypass blackscreen guard active)", "DEBUG")
        else
          c.log("Overview render executed with updated model", "DEBUG")
        end
      end

      for _, r in ipairs(rendered) do
        if c.log then
          if r.ok then
            c.log(("UI render ok view=%s monitor=%s role=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role)), "DEBUG")
          else
            c.log(("UI render failed view=%s monitor=%s role=%s error=%s"):format(
              tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)
            ), "ERROR")
          end
        end
      end
  end
  controller.handle_action = function(action)
    if not action or not action.type then return false end
    if action.type == "profile" and action.name and c.calc.apply_profile then c.calc.apply_profile(action.name); return true end
    if action.type == "auto" and c.calc.set_auto_profile then c.calc.set_auto_profile(not (c.calc.get_auto_profile and c.calc.get_auto_profile())); return true end
    if action.type == "rt_hold" and c.calc.set_rt_global_off_hold then c.calc.set_rt_global_off_hold(not (c.calc.get_rt_global_off_hold and c.calc.get_rt_global_off_hold())); return true end
    return false
  end
  controller.handle_input = function(event)
    if c.view_manager and c.view_manager.handle_input then
      local hit = c.view_manager:handle_input(event)
      if hit then return controller.handle_action(hit) end
    end
    return false
  end
  return controller
end

return M
