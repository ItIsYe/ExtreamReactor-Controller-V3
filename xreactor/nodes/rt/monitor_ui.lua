local ui = require("core.ui")
local ui_router = require("core.ui_router")
local support_ui_pages = require("nodes.support.ui_pages")
local mockup_pages = require("nodes.rt.mockup_pages")
local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local M = {
  monitor_router = nil,
  last_monitor_update = 0,
  main_monitor_name = nil,
  last_monitor = nil,
  last_capacity_ready = nil,
}

local function num(value, fallback)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then return parsed end
  end
  return fallback
end

local function try_set_scale(monitor, scale)
  if monitor and type(scale) == "number" then ui.setScale(monitor, scale) end
end

local function normalize_monitor_result(result)
  if type(result) == "table" then
    if result.mon then return result.mon, result.name end
    if result.monitor then return result.monitor, result.name end
  end
  return result
end

local function resolve_monitor(monitor_adapter, preferred_name, monitor_scale)
  if type(monitor_adapter) ~= "table" then return nil, "monitor adapter missing" end
  if type(monitor_adapter.find) == "function" then
    local monitor, name = normalize_monitor_result(monitor_adapter.find(preferred_name, "largest", monitor_scale, "RT"))
    if monitor then return monitor, name end
  end
  if type(monitor_adapter.wrap) == "function" and preferred_name then
    local monitor = monitor_adapter.wrap(preferred_name)
    if monitor then
      try_set_scale(monitor, monitor_scale)
      return monitor, preferred_name
    end
  end
  if preferred_name and peripheral and type(peripheral.wrap) == "function" then
    local monitor = peripheral.wrap(preferred_name)
    if monitor then
      try_set_scale(monitor, monitor_scale)
      return monitor, preferred_name
    end
  end
  return nil, preferred_name and ("monitor unavailable: " .. tostring(preferred_name)) or "no monitor found"
end

local rt_status_base

-- Meldet die Node selbst ein Problem (rt2_problems.lua), ist die Ampel
-- mindestens orange -- sonst zeigte sie gruen, waehrend MASTER "RT meldet
-- ein Problem" anzeigt.
local function rt_status(model)
  local status = rt_status_base(model)
  local problems = type(model.problems) == "table" and model.problems or {}
  if #problems > 0 and status ~= "EMERGENCY" then return "WARNING" end
  return status
end

function rt_status_base(model)
  -- Reihenfolge wie in mockup_pages.lua's rt_status(): assignment_state (vom
  -- Master zugewiesen) zuerst pruefen, sonst faerbt die Ampel einen bewusst
  -- geparkten/abgeschalteten Knoten faelschlich als "LIMITED" (Kapazitaet
  -- wird gelernt) statt "muted" (heruntergefahren/wartet auf Zuweisung).
  local assignment = tostring(model.assignment_state or "")
  if assignment == "shutdown" or assignment == "shed" or assignment == "standby" then return "muted" end
  if assignment == "startup" then return "LIMITED" end
  if not model.capacity_ready then return "LIMITED" end
  local snapshot = model.snapshot and model.snapshot.snapshot or {}
  local target = num(model.target_power, num(snapshot.target_power, 0))
  local actual = num(snapshot.actual_output, 0)
  if target <= 0 then return "muted" end
  local ratio = actual / target
  if ratio >= 0.85 and ratio <= 1.15 then return "OK" end
  if ratio < 0.5 then return "EMERGENCY" end
  return "WARNING"
end

-- Single inspect() pass per reactor, producing both the per-device detail
-- record AND the min/max/avg temperature stats -- previously two separate
-- functions each called reactor_adapter.inspect() independently for the
-- same reactors, doubling the (expensive, real-peripheral-call) inspect
-- sweep on every monitor update for no reason.
function M.build_reactor_status(devices, reactor_adapter, log_prefix)
  local list = {}
  local min_temp, max_temp, sum_temp, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.reactors or {}) do
    local info = reactor_adapter and type(reactor_adapter.inspect) == "function" and entry and entry.name and reactor_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local temp = info.temperature
    if type(temp) == "number" then
      count = count + 1
      sum_temp = sum_temp + temp
      if not min_temp or temp < min_temp then min_temp = temp end
      if not max_temp or temp > max_temp then max_temp = temp end
    end
    local rods = info.control_rod_level
    if rods == nil and reactor_adapter and type(reactor_adapter.read_control_rods) == "function" and entry and entry.name then
      rods = reactor_adapter.read_control_rods(entry.name, log_prefix)
    end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      temperature = info.temperature,
      fuel = info.fuel,
      energy_stored = info.energy_stored,
      energy_output = info.energy_output,
      waste = info.waste,
      active = info.active,
      is_actively_cooled = info.is_actively_cooled,
      rods = rods,
      steam_production = info.steam,
      coolant_amount = info.coolant_amount,
      coolant_amount_max = info.coolant_amount_max,
      coolant_filled_percentage = info.coolant_filled_percentage,
    }
  end
  return list, min_temp, max_temp, count > 0 and (sum_temp / count) or nil
end

-- Same consolidation as M.build_reactor_status() above, for turbines.
--
-- flow_reasons (optional, nach Peripheriename): was der Regler je Turbine
-- zuletzt entschieden hat. Der Grund kommt vom Aufrufer, wie
-- capacity_override auch -- die Oberflaeche entscheidet nichts selbst.
--
-- EIN Leseweg: adapters/turbine.lua's inspect(), derselbe, den der Regler
-- liest (rt2_adapter.lua). Bis v814 gab es hier einen zweiten: lieferte
-- inspect() keine Drehzahl oder keinen Durchfluss, las diese Funktion per
-- peripheral.wrap() und dem Faehigkeiten-Cache ctx.capability_cache noch
-- einmal nach. Das war in beide Richtungen falsch:
--
--   * Der Cache wird von der Discovery einmal je Name geschrieben und nie
--     erneuert. Kam eine Turbine nach dem Chunk-Laden zuerst mit
--     verkuerzter Methodenliste zurueck, blieb der Rueckfall fuer immer
--     stumm -- obwohl der Adapter laengst wieder las.
--   * Ging er doch, zeigte der Schirm einen Wert, den der Regler NICHT
--     hatte (beim Durchfluss sogar eine andere Groesse: getFluidFlowRate
--     ist der Verbrauch, nicht der Sollwert). So sah die Oberflaeche beim
--     Livetest auf node-101 normal aus, waehrend der Regler blind war
--     (tests/rt2_unreadable_turbine_write_test.lua).
--
-- Jetzt zeigt der Schirm, was der Regler sieht: "nicht lesbar" bleibt
-- unbekannt (nil -> "-"), nie der String "n/a" (der wuerde das
-- Zahlenformat der Turbinenseite sprengen).
function M.build_turbine_status(devices, turbine_adapter, log_prefix, flow_reasons)
  local list, total_output = {}, 0
  local min_rpm, max_rpm, sum_rpm, rpm_count = nil, nil, 0, 0
  local can_inspect = turbine_adapter and type(turbine_adapter.inspect) == "function"
  for _, entry in ipairs(devices.turbines or {}) do
    local info = can_inspect and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local rpm, flow = num(info.rpm, nil), num(info.flow, nil)
    if rpm then
      rpm_count = rpm_count + 1
      sum_rpm = sum_rpm + rpm
      if not min_rpm or rpm < min_rpm then min_rpm = rpm end
      if not max_rpm or rpm > max_rpm then max_rpm = rpm end
    end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = rpm,
      flow = flow,
      energy = energy,
      active = info.active,
      inductor = info.coil_engaged,
      flow_reason = flow_reasons and entry.name and flow_reasons[entry.name] or nil,
    }
  end
  return list, total_output, min_rpm, max_rpm, rpm_count > 0 and (sum_rpm / rpm_count) or nil
end

function M.update_status_snapshot(ctx)
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary() or {}
  local reactors, min_temp, max_temp, avg_temp = M.build_reactor_status(ctx.devices, ctx.reactor_adapter, ctx.log_prefix)
  local turbines, actual_output, min_rpm, max_rpm, avg_rpm = M.build_turbine_status(
    ctx.devices, ctx.turbine_adapter, ctx.log_prefix, ctx.turbine_flow_reasons)
  -- ctx.capacity_override: der Lernzustand des Reglers, vom Aufrufer
  -- gegeben. Als es hier noch einen zweiten Lernzustand gab, stand auf dem
  -- RT-Schirm "KAPAZITAET WIRD GELERNT / CAPACITY 0.0", waehrend im
  -- Terminal daneben "Einlernen FERTIG: ... RF/t" lief -- zwei Anzeigen
  -- derselben Node aus zwei Quellen. Die Oberflaeche entscheidet nichts
  -- selbst: sie nimmt, was der Aufrufer ihr gibt.
  local capacity = ctx.capacity_override or {}
  ctx.last_status_snapshot = {
    ts = os.epoch("utc"),
    node_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or ctx.config.node_id,
    summary = summary,
    min_temp = min_temp,
    max_temp = max_temp,
    avg_temp = avg_temp,
    min_rpm = min_rpm,
    max_rpm = max_rpm,
    avg_rpm = avg_rpm,
    steam_amount = ctx.get_available_steam(),
    target_power = ctx.targets and ctx.targets.power or nil,
    target_percent = ctx.targets and ctx.targets.power_percent or nil,
    target_rpm = ctx.targets and ctx.targets.rpm or nil,
    target_steam = ctx.targets and ctx.targets.steam or nil,
    actual_output = actual_output,
    capacity_max = capacity.max_output or (ctx.targets and ctx.targets.capacity_max) or 0,
    capacity_ready = capacity.ready == true,
    capacity_source = capacity.reason or (ctx.targets and ctx.targets.capacity_source) or "unknown",
    capacity_stable_turbines = capacity.at_target or 0,
    capacity_total_turbines = capacity.total_turbines or 0,
    -- Wieviele Turbinen fuer den Messpunkt noetig sind (80 % der Flotte).
    capacity_required_turbines = capacity.required_turbines or 0,
    reactors = reactors,
    turbines = turbines,
  }
  return ctx.last_status_snapshot
end

function M.init(monitor_adapter, configured_monitor, monitor_scale)
  M.monitor_router = nil
  M.last_monitor_update = 0
  local monitor, name_or_err = resolve_monitor(monitor_adapter, configured_monitor, monitor_scale)
  if not monitor then return nil, name_or_err end
  M.main_monitor_name = name_or_err
  return monitor, name_or_err
end

-- Skalierung live aendern ohne M.monitor_router zurueckzusetzen (M.init()
-- tut das fuer den Boot-Fall, wuerde aber bei Touch-ausgeloester
-- Skalen-Aenderung den Nutzer ungewollt zurueck auf Overview werfen).
function M.set_scale(monitor, scale)
  if not monitor then return end
  try_set_scale(monitor, scale)
end

local ok_ampel_mod, ampel_mod = pcall(require, "optional.ampel")
local ampel_instance = ok_ampel_mod and type(ampel_mod) == "table" and type(ampel_mod.new) == "function" and ampel_mod.new() or nil

function M.update(monitor, ctx)
  if not monitor then return ctx.last_status_snapshot end
  local now = os.epoch("utc")
  -- Der Vergleich gilt nur VORWAERTS. Springt os.epoch("utc") zurueck (Welt
  -- neu geladen), liegt M.last_monitor_update in der Zukunft, die Differenz
  -- ist negativ und damit immer kleiner als das Intervall -- der Schirm
  -- waere bis zum Aufholen der Uhr eingefroren, und zwar auf einem alten
  -- Bild, das gesund aussieht. Dieselbe Regel wie im Regler (siehe
  -- rt2_master_link.lua's is_connected und rt2_unit.lua's Stellintervall):
  -- ein Zeitstempel aus der Zukunft wird verworfen, nicht ausgesessen.
  local since = now - M.last_monitor_update
  if since >= 0 and since < (ctx.config.monitor_interval * 1000) then
    return ctx.last_status_snapshot
  end
  M.last_monitor_update = now

  local snapshot = M.update_status_snapshot(ctx)
  local health_payload = ctx.build_health_payload()
  local summary = ctx.devices.registry_summary or ctx.registry:get_summary()
  local comms_diag = ctx.comms and ctx.comms:get_diagnostics() or {}
  local metrics = comms_diag.metrics or {}
  local master_state, master_age = "UNKNOWN", "n/a"

  for _, peer in pairs(comms_diag.peers or {}) do
    if peer.role == ctx.constants.roles.MASTER then
      master_state = peer.down and "DOWN" or "OK"
      master_age = peer.age and (math.floor(peer.age) .. "s") or "n/a"
      break
    end
  end

  local node_id = snapshot and snapshot.node_id or ctx.config.node_id
  local alert_payload = ctx.master_alerts and ctx.master_alerts.by_node and ctx.master_alerts.by_node[node_id] or nil
  local targets = ctx.targets or {}
  local model = {
    snapshot = { snapshot = snapshot, local_alerts = alert_payload and alert_payload.critical or 0 },
    health = health_payload,
    summary = summary,
    comms = comms_diag,
    metrics = metrics,
    master_state = master_state,
    master_age = master_age,
    last_scan = ctx.devices.last_scan_ts and (math.floor((now - ctx.devices.last_scan_ts) / 1000) .. "s") or "n/a",
    last_command = ctx.last_command,
    last_command_ts = ctx.last_command_ts and (math.floor((now - ctx.last_command_ts) / 1000) .. "s") or "n/a",
    local_alerts = alert_payload and alert_payload.top or {},
    local_alerts_critical = alert_payload and alert_payload.critical or 0,
    node_id = node_id,
    current_state = ctx.current_state,
    -- ctx.node_state: der projizierte Knotenzustand des Reglers (siehe
    -- rt2_projection.lua). Die frueher hier stehende Zustandsmaschine ist
    -- mit v1 entfallen.
    node_state = ctx.node_state or ctx.current_state,
    configured_reactors = ctx.configured_reactors,
    configured_turbines = ctx.configured_turbines,
    target_power = targets.power,
    target_percent = targets.power_percent,
    target_rpm = targets.rpm or (ctx.get_target_rpm and ctx.get_target_rpm()),
    target_steam = targets.steam,
    assignment_state = targets.assignment_state,
    capacity_max = snapshot and snapshot.capacity_max or 0,
    capacity_ready = snapshot and snapshot.capacity_ready or false,
    capacity_source = snapshot and snapshot.capacity_source or "unknown",
    capacity_stable_turbines = snapshot and snapshot.capacity_stable_turbines or 0,
    capacity_total_turbines = snapshot and snapshot.capacity_total_turbines or 0,
    capacity_required_turbines = snapshot and snapshot.capacity_required_turbines or 0,
    binding = ctx.binding,
    build_label = ctx.build_label or ctx.manifest_id or ctx.release_id,
    -- ctx.monitor_scale wird von main.lua gesetzt (der aktuell wirksame,
    -- ggf. per Touch geaenderte Wert).
    monitor_scale = ctx.monitor_scale,
    -- Verlorene/verspaetete Timer der Lauf-Schleifen, von main.lua gesetzt.
    loop_stats = ctx.loop_stats,
    -- Was MASTER als "RT meldet ein Problem" zeigt (rt2_problems.lua).
    problems = ctx.rt_problems or {},
  }

  if not M.monitor_router then
    M.monitor_router = ui_router.new({
      pages = {
        { name = "Overview", render = mockup_pages.render_overview },
        { name = "Turbines", render = mockup_pages.render_turbines },
        { name = "Reactors", render = mockup_pages.render_reactors },
        { name = "Diagnostics", render = mockup_pages.render_diagnostics },
      },
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true },
    })
  end

  M.last_monitor = monitor
  M.monitor_router:render(monitor, model)

  pcall(function()
    if not ampel_instance then return end
    ampel_instance.render(M.main_monitor_name, rt_status(model))
  end)

  pcall(function()
    if M.last_capacity_ready == nil then
      M.last_capacity_ready = model.capacity_ready == true
      return
    end
    if model.capacity_ready == true and M.last_capacity_ready == false then
      local ok_spk_mod, spk_mod = pcall(require, "optional.speaker_alarm")
      if ok_spk_mod and type(spk_mod) == "table" and type(spk_mod.new) == "function" then
        local speaker = spk_mod.new()
        pcall(speaker.play, "capacity_learned")
      end
    end
    M.last_capacity_ready = model.capacity_ready == true
  end)

  return snapshot
end

function M.handle_input(event)
  if M.monitor_router then M.monitor_router:handle_input(event) end
  if utils and event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
    local page = M.monitor_router and M.monitor_router:current()
    if page and page.name == "Diagnostics" and M.last_monitor then
      local _, h = ui.getSize(M.last_monitor)
      if h then support_ui_pages.handle_log_mode_touch(event[3], event[4], h, utils, 1) end
      local hits = mockup_pages.scale_hit_cache and mockup_pages.scale_hit_cache[M.last_monitor]
      if hits then
        local x, y = event[3], event[4]
        local function in_zone(zone)
          return zone and y == zone.y and x >= zone.x1 and x <= zone.x2
        end
        if in_zone(hits.minus) and type(M.on_scale_change) == "function" then
          M.on_scale_change(-0.5)
        elseif in_zone(hits.plus) and type(M.on_scale_change) == "function" then
          M.on_scale_change(0.5)
        end
      end
    end
  end
end

return M
