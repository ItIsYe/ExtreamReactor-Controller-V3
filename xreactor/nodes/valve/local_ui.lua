-- nodes/valve/local_ui.lua
--
-- Fixed 51x19 local SCADA display for the VALVE node's own computer terminal.
-- ui_scale=1.0 uses the normal card layout. ui_scale=0.5 selects a denser
-- COMPACT layout; the built-in computer terminal has no setTextScale API,
-- so 0.5 is a layout-density mode here, not a physical font resize.
-- Presentation plus ONE deliberately one-way local safety action only:
-- BLOCKED + forced physical write/readback. There is intentionally NO local
-- OPEN action. Normal opening remains owned by the trusted FUEL/VALVE network
-- command path in controller.lua.
--
-- beta-v631 addition: passive HOP sensor status. The UI only reads reporter
-- state/timing supplied by main.lua. It never scans inventories itself and
-- never changes hop timing, routing, valve commands, pairing or fail-safe logic.

local M = {}
M.__index = M

local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local EXPECTED_W = 51
local EXPECTED_H = 19
local ACTION_X = 2
local ACTION_Y = 14
local ACTION_W = 48
local ACTION_H = 3
local COMPACT_ACTION_X = 5
local COMPACT_ACTION_Y = 12
local COMPACT_ACTION_W = 42
local COMPACT_ACTION_H = 3
local NORMAL_SCALE = 1.0
local COMPACT_SCALE = 0.5
local AGE_BUCKET_S = 2

local function normalize_ui_scale(value)
  local n = tonumber(value)
  if n == COMPACT_SCALE then return COMPACT_SCALE end
  return NORMAL_SCALE
end

local function now_ms(os_api)
  if os_api and type(os_api.epoch) == "function" then
    local ok, value = pcall(os_api.epoch, "utc")
    if ok and type(value) == "number" then return value end
  end
  return 0
end

local function fit(value, width)
  return mux.fit(tostring(value == nil and "-" or value), math.max(1, width))
end

local function hit(rect, x, y)
  return rect ~= nil
    and y >= rect.y and y <= (rect.y2 or rect.y)
    and x >= rect.x1 and x <= rect.x2
end

local function bool_text(value, yes, no)
  if value == true then return yes or "JA" end
  if value == false then return no or "NEIN" end
  return "?"
end

local function terminal_from(term_api)
  if not term_api then return nil end
  if type(term_api.native) == "function" then
    local ok, target = pcall(term_api.native)
    if ok and target then return target end
  end
  if type(term_api.current) == "function" then
    local ok, target = pcall(term_api.current)
    if ok and target then return target end
  end
  return term_api
end

local function age_seconds(ts, os_api)
  local stamp = tonumber(ts)
  if not stamp or stamp <= 0 then return nil end
  return math.max(0, math.floor((now_ms(os_api) - stamp) / 1000))
end

local function age_text(ts, os_api)
  local age = age_seconds(ts, os_api)
  if age == nil then return "-" end
  if age >= 3600 then
    return string.format("%dh%02dm", math.floor(age / 3600), math.floor((age % 3600) / 60))
  end
  if age >= 60 then return string.format("%dm%02ds", math.floor(age / 60), age % 60) end
  return tostring(age) .. "s"
end

local function age_bucket(ts, os_api)
  local age = age_seconds(ts, os_api)
  if age == nil then return -1 end
  return math.floor(age / AGE_BUCKET_S)
end

local function actuator_status(state)
  if state.initialized ~= true or state.last_write_error ~= nil then return "WARNING" end
  return "OK"
end

local function physical_status(state)
  if state.initialized ~= true or state.last_write_error ~= nil then
    return "WARNING", "ZUSTAND UNBESTAETIGT", "AKTOR/READBACK PRUEFEN"
  end
  if state.current_high == true then
    return "EMERGENCY", "VENTIL BLOCKIERT", "SAFE-ZUSTAND AKTIV"
  end
  return "OK", "VENTIL OFFEN", "ROUTE FREIGEGEBEN"
end

local function hop_status(hop, os_api)
  hop = type(hop) == "table" and hop or {}
  local configured = hop.configured == true
    or (type(hop.chest) == "string" and hop.chest ~= "")
  local interval_s = math.max(1, tonumber(hop.interval_s) or 4)

  if not configured then
    return "OFFLINE", "AUS", "keine Kiste konfiguriert", nil
  end
  if hop.enabled ~= true then
    return "WARNING", "FEHLER", "Kiste nicht erreichbar", nil
  end
  if hop.modem_ready == false then
    return "WARNING", "KEIN MODEM", "HOP_SCAN kann nicht senden", nil
  end

  local age = age_seconds(hop.last_scan_ms, os_api)
  if age == nil then
    return "LIMITED", "WARTE", "noch kein erfolgreicher Scan", nil
  end

  -- UI-only health classification. It does not feed back into routing or
  -- fail-safe. Allow two normal intervals plus one second scheduling slack.
  local stale_after = interval_s * 2 + 1
  if age > stale_after then
    return "WARNING", "STALE", "letzter Scan zu alt", age
  end
  return "OK", "AKTIV", "passive HOP_SCAN Meldungen", age
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.controller) == "table", "VALVE local UI requires controller")
  local self = setmetatable({
    controller = opts.controller,
    node_id = tostring(opts.node_id or "VALVE-?"),
    label = type(opts.label) == "string" and opts.label ~= "" and opts.label or nil,
    modem_name = opts.modem_name,
    is_master_reachable = opts.is_master_reachable or function() return false end,
    get_comms_diagnostics = opts.get_comms_diagnostics or function() return {} end,
    get_hop_status = opts.get_hop_status or function() return {} end,
    term_api = opts.term_api or term,
    os = opts.os_api or os,
    ui_scale = normalize_ui_scale(opts.ui_scale),
    target = opts.target,
    safe_button = nil,
    last_snapshot = nil,
    force_redraw = true,
    action_message = nil,
    action_status = nil,
    action_ts = nil,
  }, M)
  if not self.target then self.target = terminal_from(self.term_api) end
  return self
end

function M:_get_target()
  if self.target then return self.target end
  self.target = terminal_from(self.term_api)
  return self.target
end

function M:_get_size()
  local target = self:_get_target()
  if not target or type(target.getSize) ~= "function" then return nil, nil end
  local ok, w, h = pcall(target.getSize)
  if ok then return tonumber(w), tonumber(h) end
  return nil, nil
end

function M:_size_ok()
  local w, h = self:_get_size()
  return w == EXPECTED_W and h == EXPECTED_H, w, h
end

function M:_read_runtime()
  local state = self.controller:get_state()
  local master_ok = self.is_master_reachable() == true

  local ok_diag, diag = pcall(self.get_comms_diagnostics)
  if not ok_diag or type(diag) ~= "table" then diag = {} end

  local ok_hop, hop = pcall(self.get_hop_status)
  if not ok_hop or type(hop) ~= "table" then hop = {} end

  return state, master_ok, diag, hop
end

function M:_snapshot(state, master_ok, diag, hop)
  local w, h = self:_get_size()
  return table.concat({
    tostring(w), tostring(h), tostring(self.ui_scale),
    tostring(state.current_high), tostring(state.initialized), tostring(state.last_write_error),
    tostring(state.sorter_name), tostring(state.actuator_mode), tostring(state.redstone_side),
    tostring(state.trusted_source), tostring(state.pairing_persisted), tostring(state.pairing_error),
    tostring(master_ok), tostring(diag.queue_depth or 0), tostring(self.modem_name),
    tostring(age_bucket(state.last_command_ts, self.os)),
    tostring(hop.configured), tostring(hop.enabled), tostring(hop.chest),
    tostring(hop.interval_s), tostring(hop.last_scan_ms), tostring(hop.modem_ready),
    tostring(age_bucket(hop.last_scan_ms, self.os)),
    tostring(self.action_message), tostring(self.action_status),
  }, "\31")
end

function M:_draw_size_error(target, w, h)
  self.safe_button = nil
  if target and type(target.setBackgroundColor) == "function" then
    pcall(target.setBackgroundColor, colorset.get("background"))
  end
  if target and type(target.clear) == "function" then pcall(target.clear) end
  if not target then return false end

  local safe_w = math.max(1, tonumber(w) or EXPECTED_W)
  mux.header(target, {
    title = "VALVE LOCAL UI", node_id = self.node_id, status = "WARNING", icon = "flow"
  })
  if h and h >= 6 then
    mux.banner(target, 2, 5, math.max(1, safe_w - 3),
      "FALSCHE TERMINALGROESSE", "WARNING", "warning")
  end
  if h and h >= 8 then
    mux.data_row(target, 2, 7, math.max(1, safe_w - 3), {
      label = "ERWARTET", value = EXPECTED_W .. "x" .. EXPECTED_H,
      status = "WARNING", icon = "config"
    })
  end
  if h and h >= 9 then
    mux.data_row(target, 2, 8, math.max(1, safe_w - 3), {
      label = "AKTUELL", value = tostring(w or "?") .. "x" .. tostring(h or "?"),
      status = "WARNING", icon = "config"
    })
  end
  if h and h >= 11 then
    mux.data_row(target, 2, 10, math.max(1, safe_w - 3), {
      label = "LOKALE AKTIONEN", value = "DEAKTIVIERT",
      status = "WARNING", icon = "warning"
    })
  end
  return false
end

function M:_render_normal_frame(target, state, master_ok, diag, hop)
  local physical_key, physical_title, physical_detail = physical_status(state)
  local actuator_key = actuator_status(state)
  local health_key = (master_ok and actuator_key == "OK") and "OK" or "WARNING"
  local hop_key, hop_title, hop_detail, hop_age = hop_status(hop, self.os)

  mux.clear(target)
  mux.header(target, {
    title = "VALVE NODE",
    node_id = self.node_id,
    status = health_key,
    icon = "flow",
  })

  mux.status_dot(target, 2, 3,
    master_ok and "MASTER ONLINE" or "MASTER OFFLINE",
    master_ok and "OK" or "WARNING", 23)
  mux.status_dot(target, 27, 3,
    actuator_key == "OK" and "AKTOR OK" or "AKTOR FEHLER",
    actuator_key, 23)

  mux.card(target, 2, 4, 48, 4, {
    title = "VENTILSTATUS", status = physical_key, icon = "flow"
  })
  mux.banner(target, 4, 5, 44, physical_title, physical_key, nil)
  mux.data_row(target, 4, 6, 44, {
    label = physical_detail,
    value = self.label and fit(self.label, 18) or "",
    status = physical_key,
    icon = "reactor",
  })

  mux.card(target, 2, 8, 24, 5, {
    title = "AKTOR", status = actuator_key, icon = "output"
  })
  mux.data_row(target, 4, 9, 20, {
    label = "MODUS", value = fit(state.actuator_mode or "none", 10), status = "text"
  })
  mux.data_row(target, 4, 10, 20, {
    label = "GERAET",
    value = fit(state.sorter_name or state.redstone_side or "-", 10),
    status = "text"
  })
  mux.data_row(target, 4, 11, 20, {
    label = "WRITE",
    value = state.last_write_error and "FEHLER"
      or (state.initialized and "BESTAETIGT" or "OFFEN"),
    status = state.last_write_error and "WARNING"
      or (state.initialized and "OK" or "LIMITED")
  })

  mux.card(target, 27, 8, 23, 5, {
    title = "SCADA / HOP",
    status = master_ok and "OK" or "WARNING",
    icon = "network"
  })
  mux.data_row(target, 29, 9, 19, {
    label = "SOURCE", value = fit(state.trusted_source or "UNPAIRED", 9),
    status = state.trusted_source and "OK" or "LIMITED"
  })
  mux.data_row(target, 29, 10, 19, {
    label = "PAIR", value = bool_text(state.pairing_persisted, "OK", "NEIN"),
    status = state.pairing_persisted and "OK" or "WARNING"
  })
  mux.data_row(target, 29, 11, 19, {
    label = "HOP", value = hop_title, status = hop_key
  })

  local hop_line
  if hop_title == "AUS" then
    hop_line = "HOP AUS | keine Kiste konfiguriert"
  else
    local chest = fit(hop.chest or "?", 16)
    local scan = hop_age ~= nil and (tostring(hop_age) .. "s") or "-"
    local interval = tostring(math.max(1, tonumber(hop.interval_s) or 4)) .. "s"
    hop_line = string.format("HOP %s | SCAN %s | INT %s", chest, scan, interval)
  end
  mux.data_row(target, 2, 13, 48, {
    label = fit(hop_line, 48), value = "", status = hop_key, icon = "storage"
  })

  local button_status =
    state.current_high == true and state.initialized and not state.last_write_error
      and "OK" or "LIMITED"
  self.safe_button = mux.button(target, ACTION_X, ACTION_Y, ACTION_W,
    "SAFE BLOCKIEREN + READBACK PRUEFEN", button_status, ACTION_H)

  local msg = self.action_message
  local msg_status = self.action_status or "text"
  if not msg or msg == "" then
    if state.last_write_error then
      msg = "AKTOR-FEHLER: " .. tostring(state.last_write_error)
      msg_status = "WARNING"
    elseif state.pairing_error then
      msg = "PAIRING-FEHLER: " .. tostring(state.pairing_error)
      msg_status = "WARNING"
    elseif hop_key == "WARNING" then
      msg = "HOP: " .. tostring(hop_detail)
      msg_status = "WARNING"
    else
      msg = string.format("MODEM %s | QUEUE %s | WRITE-AGE %s",
        tostring(self.modem_name or "auto"),
        tostring(diag.queue_depth or 0),
        age_text(state.last_command_ts, self.os))
      msg_status = "muted"
    end
  end

  mux.data_row(target, 2, 17, 48, {
    label = fit(msg, 48), value = "", status = msg_status, icon = "warning"
  })
  mux.data_row(target, 2, 18, 48, {
    label = "LOKALER SAFE-MODUS",
    value = "OEFFNEN NUR VIA FUEL",
    status = "LIMITED",
    icon = "config"
  })
  mux.data_row(target, 2, 19, 48, {
    label = "NODE",
    value = fit(self.label or self.node_id, 24),
    status = health_key,
    icon = "network"
  })
  return true
end

function M:_render_compact_frame(target, state, master_ok, diag, hop)
  local physical_key, physical_title, physical_detail = physical_status(state)
  local actuator_key = actuator_status(state)
  local health_key = (master_ok and actuator_key == "OK") and "OK" or "WARNING"
  local hop_key, hop_title, hop_detail, hop_age = hop_status(hop, self.os)

  -- ui_scale 0.5 on the built-in computer terminal is a reduced-density
  -- layout, not a physical font scale. Keep deliberate empty rows and side
  -- margins so the 51x19 display does not look packed edge-to-edge.
  mux.clear(target)
  mux.header(target, {
    title = "VALVE NODE",
    node_id = self.node_id,
    status = health_key,
    icon = "flow",
  })

  mux.banner(target, 4, 4, 44, physical_title, physical_key, nil)
  mux.data_row(target, 5, 5, 42, {
    label = physical_detail,
    value = self.label and fit(self.label, 17) or "",
    status = physical_key,
    icon = "flow",
  })

  -- Row 6 intentionally blank.
  mux.data_row(target, 5, 7, 42, {
    label = "MASTER",
    value = master_ok and "ONLINE" or "OFFLINE",
    status = master_ok and "OK" or "WARNING",
    icon = "network",
  })

  local actuator_value = fit(state.sorter_name or state.redstone_side or "-", 15)
  if state.last_write_error then
    actuator_value = "FEHLER"
  elseif state.initialized then
    actuator_value = actuator_value .. " / OK"
  else
    actuator_value = actuator_value .. " / ?"
  end
  mux.data_row(target, 5, 8, 42, {
    label = "AKTOR " .. tostring(state.actuator_mode or "none"),
    value = fit(actuator_value, 20),
    status = actuator_key,
    icon = "output",
  })

  local source = fit(state.trusted_source or "UNPAIRED", 13)
  local pair = bool_text(state.pairing_persisted, "PAIR OK", "UNPAIRED")
  mux.data_row(target, 5, 9, 42, {
    label = "SCADA",
    value = fit(source .. " / " .. pair, 22),
    status = (master_ok and state.pairing_persisted) and "OK" or "LIMITED",
    icon = "network",
  })

  local hop_value
  if hop_title == "AUS" then
    hop_value = "AUS"
  elseif hop_age ~= nil then
    hop_value = string.format("%s / %ss / %ss",
      hop_title,
      tostring(hop_age),
      tostring(math.max(1, tonumber(hop.interval_s) or 4)))
  else
    hop_value = hop_title
  end
  mux.data_row(target, 5, 10, 42, {
    label = "HOP",
    value = fit(hop_value, 23),
    status = hop_key,
    icon = "storage",
  })

  -- Row 11 intentionally blank before the only local action.
  local button_status =
    state.current_high == true and state.initialized and not state.last_write_error
      and "OK" or "LIMITED"
  self.safe_button = mux.button(target,
    COMPACT_ACTION_X, COMPACT_ACTION_Y, COMPACT_ACTION_W,
    "SAFE BLOCKIEREN + READBACK PRUEFEN", button_status, COMPACT_ACTION_H)

  -- Row 15 intentionally blank after the action.
  local msg = self.action_message
  local msg_status = self.action_status or "muted"
  if not msg or msg == "" then
    if state.last_write_error then
      msg = "AKTOR-FEHLER: " .. tostring(state.last_write_error)
      msg_status = "WARNING"
    elseif state.pairing_error then
      msg = "PAIRING-FEHLER: " .. tostring(state.pairing_error)
      msg_status = "WARNING"
    elseif hop_key == "WARNING" then
      msg = "HOP: " .. tostring(hop_detail)
      msg_status = "WARNING"
    else
      msg = string.format("MODEM %s  QUEUE %s  AGE %s",
        tostring(self.modem_name or "auto"),
        tostring(diag.queue_depth or 0),
        age_text(state.last_command_ts, self.os))
      msg_status = "muted"
    end
  end

  mux.data_row(target, 5, 16, 42, {
    label = fit(msg, 42), value = "", status = msg_status, icon = "config"
  })
  mux.data_row(target, 5, 17, 42, {
    label = "LOCAL SAFE", value = "OEFFNEN NUR VIA FUEL",
    status = "LIMITED", icon = "config"
  })
  mux.data_row(target, 5, 18, 42, {
    label = "NODE", value = fit(self.label or self.node_id, 22),
    status = health_key, icon = "network"
  })
  mux.data_row(target, 5, 19, 42, {
    label = "UI", value = "0.5 REDUZIERT",
    status = "muted", icon = "config"
  })
  return true
end

function M:render(force)
  local target = self:_get_target()
  if not target then return false end

  local state, master_ok, diag, hop = self:_read_runtime()
  local snapshot = self:_snapshot(state, master_ok, diag, hop)
  if not force and not self.force_redraw and snapshot == self.last_snapshot then
    return false
  end

  self.force_redraw = false
  self.last_snapshot = snapshot

  local size_ok, w, h = self:_size_ok()
  if not size_ok then return self:_draw_size_error(target, w, h) end
  if self.ui_scale == COMPACT_SCALE then
    return self:_render_compact_frame(target, state, master_ok, diag, hop)
  end
  return self:_render_normal_frame(target, state, master_ok, diag, hop)
end

function M:handle_event(event)
  if type(event) ~= "table" then return false end
  local kind = event[1]

  if kind == "term_resize" then
    self.safe_button = nil
    self.force_redraw = true
    return false
  end

  if kind ~= "mouse_click" then return false end
  local button, x, y = tonumber(event[2]), tonumber(event[3]), tonumber(event[4])
  if button ~= 1 or not x or not y then return false end

  local size_ok = self:_size_ok()
  if not size_ok then return false end
  if not hit(self.safe_button, x, y) then return false end

  -- Deliberately one-way: this UI may ONLY command BLOCKED (high=true).
  -- Opening remains exclusively under the trusted network command path.
  local ok = self.controller:apply_valve(true, true) == true
  local state = self.controller:get_state()
  if ok and state.initialized == true and state.current_high == true
      and state.last_write_error == nil then
    self.action_message = "SAFE BLOCKIERT + PHYSISCH BESTAETIGT"
    self.action_status = "OK"
  else
    self.action_message = "SAFE-BLOCK FEHLER: "
      .. tostring(state.last_write_error or "unbestaetigt")
    self.action_status = "WARNING"
  end
  self.action_ts = now_ms(self.os)
  self.force_redraw = true
  return true
end

function M:get_touch_geometry()
  return {
    expected_width = EXPECTED_W,
    expected_height = EXPECTED_H,
    ui_scale = self.ui_scale,
    safe_button = self.safe_button,
  }
end

M.NORMAL_SCALE = NORMAL_SCALE
M.COMPACT_SCALE = COMPACT_SCALE
M.SUPPORTED_SCALES = { 0.5, 1.0 }

return M
