local constants = require("shared.constants")
local comms_lib = require("core.comms")
local network_lib = require("core.network")
local utils = require("core.utils")
local build_info = require("shared.build_info")

local comms_service = {}

local function control_channel(config)
  return (config.channels and config.channels.control) or constants.channels.CONTROL
end

local function status_channel(config)
  return (config.channels and config.channels.status) or constants.channels.STATUS
end

local function sanitize_channels(config)
  config.channels = type(config.channels) == "table" and config.channels or {}
  if type(config.channels.control) ~= "number" then
    config.channels.control = constants.channels.CONTROL
  end
  if type(config.channels.status) ~= "number" then
    config.channels.status = constants.channels.STATUS
  end
end

local function normalize_role(role)
  if role == nil then return nil end
  return tostring(role):upper():gsub("_", "-")
end

local function payload_looks_rt(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.rt) == "table" then return true end
  if type(payload.turbines) == "table" or type(payload.reactors) == "table" or type(payload.modules) == "table" then return true end
  if payload.turbine_rpm ~= nil or payload.steam ~= nil or payload.ramp_state ~= nil then return true end
  if payload.mode ~= nil and (payload.output ~= nil or payload.state ~= nil) then return true end
  return false
end

local function count_keys(value)
  if type(value) ~= "table" then return 0 end
  local n = 0
  for _, _ in pairs(value) do n = n + 1 end
  return n
end

local function yesno(value)
  return value and "yes" or "no"
end

-- Empfangsfilter fuer jede Rolle AUSSER MASTER (core/comms.lua,
-- payload_filter; Funk-Hygiene v821). Jede Node hoert jede Meldung jeder
-- anderen Node mit. Den INHALT braucht eine Rolle ausser MASTER nur:
--   * von MASTER (Lebenszeichen, Alarme, Kommandos, Fuellstand-Relais)
--   * bei allem mit Ziel (dst) -- Kommandos, Quittungen, gezielte Meldungen
--   * bei jedem Typ ausser Heartbeat/Status/Hello/Alarm (Fehler wie
--     PROTO_MISMATCH, Quittungen, ...)
-- Von Heartbeat/Status/Hello/Alarm der uebrigen Nodes zaehlt nur der
-- Absender (Peer-Tabelle: wer lebt -- fuer FUEL die Ventil-Erreichbarkeit).
-- Geprueft fuer RT, ENERGY, WATER, REPROCESSOR, VALVE und FUEL: deren
-- on_message werten nur MASTER-Meldungen und PROTO_MISMATCH aus. MASTER
-- braucht alles und bekommt diesen Filter NICHT.
function comms_service.follower_payload_filter()
  local types = constants.message_types
  local peer_only = {
    [types.HEARTBEAT] = true, [types.STATUS] = true,
    [types.HELLO] = true, [types.ALERT] = true,
  }
  return function(raw)
    if raw.role == constants.roles.MASTER then return true end
    if raw.dst ~= nil then return true end
    if not peer_only[raw.type] then return true end
    return false
  end
end

function comms_service.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name or "COMMS",
    config = opts.config or {},
    log_prefix = opts.log_prefix or "COMMS",
    role = opts.role,
    node_id = opts.node_id,
    label = opts.label,
    on_message = opts.on_message,
    on_command = opts.on_command,
    on_status = opts.on_status,
    on_heartbeat = opts.on_heartbeat,
    on_alert = opts.on_alert,
    on_error = opts.on_error,
    -- Optional: von welchen Nachrichten diese Rolle den INHALT braucht
    -- (core/comms.lua, comms.init / receive_peer_only). Ohne: alle.
    payload_filter = opts.payload_filter,
    -- Funk-Hygiene v822: false = diese Rolle braucht die Meldungen der
    -- anderen Nodes nicht und schliesst den Uplink-Kanal (status, 6501),
    -- sobald MASTER nachweislich auf dem Downlink (control, 6500) sendet.
    -- Ohne Angabe: offen wie bisher (MASTER, FUEL, alles Unbekannte).
    listen_uplink = opts.listen_uplink ~= false,
    -- Optional, fuer eine Rolle, die den Uplink hoert (FUEL, v823):
    -- function() -> can_close, reason. Liefert sie true, braucht die Rolle
    -- den Uplink gerade nicht und schliesst ihn wie eine Folge-Node --
    -- solange MASTER auf dem Downlink sendet. Ohne: offen wie bisher.
    uplink_close_check = opts.uplink_close_check,
    uplink = { closed = false, master_downlink_ms = nil, opened_ms = nil, closes = 0, reopens = 0 },
    network = nil,
    comms = nil,
    rx_diag_seen = {},
    -- COMMS muss ein modem_message sofort verarbeiten (ACK/Dedupe/Retry),
    -- meldet sich daher immer fuer Event-Ticks an.
    wants_events = true
  }
  return setmetatable(self, { __index = comms_service })
end

function comms_service:trace_master_rx(message)
  if self.log_prefix ~= "MASTER" or type(message) ~= "table" then return end
  local payload = type(message.payload) == "table" and message.payload or {}
  local role = normalize_role(message.role)
  local payload_role = normalize_role(payload.role)
  local meta_role = normalize_role(type(payload.meta) == "table" and payload.meta.role or nil)
  local interesting = payload_looks_rt(payload) or role == "RT-NODE" or payload_role == "RT-NODE" or meta_role == "RT-NODE"
  if not interesting and role == "ENERGY-NODE" then return end
  local node_id = utils.normalize_node_id(message.node_id or message.sender_id or message.src)
  local key = tostring(node_id) .. ":" .. tostring(message.type) .. ":" .. tostring(message.role or "-") .. ":" .. tostring(payload.role or "-") .. ":" .. tostring(meta_role or "-")
  if self.rx_diag_seen[key] then return end
  self.rx_diag_seen[key] = true
  utils.log(self.log_prefix, ("RX diag node=%s type=%s sender=%s role=%s payload_role=%s meta_role=%s keys=%d mode=%s state=%s output=%s turbines=%s reactors=%s modules=%s"):format(
    tostring(node_id),
    tostring(message.type or "?"),
    tostring(message.sender_id or message.src or "?"),
    tostring(message.role or "-"),
    tostring(payload.role or "-"),
    tostring(meta_role or "-"),
    count_keys(payload),
    yesno(payload.mode ~= nil),
    yesno(payload.state ~= nil),
    yesno(payload.output ~= nil),
    yesno(type(payload.turbines) == "table"),
    yesno(type(payload.reactors) == "table"),
    yesno(type(payload.modules) == "table")
  ), "INFO")
end

local function now_ms()
  return os.epoch("utc")
end

-- MASTER sendet alles auf dem Downlink (control), jede andere Rolle ihre
-- Lebenszeichen, Status, Alarme, Hello und Quittungen auf dem Uplink
-- (status). Siehe comms_service:handle_event().
local function master_role()
  return normalize_role((constants.roles or {}).MASTER or "MASTER")
end

function comms_service:is_master()
  return normalize_role(self.network and self.network.role or self.role or self.config.role)
    == master_role()
end

function comms_service:_broadcast_channel()
  if self:is_master() then return control_channel(self.config) end
  return status_channel(self.config)
end

local function command_target(message)
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  return type(command) == "table" and command.target or nil
end

function comms_service:_authorize_command(message)
  if type(message) ~= "table" then return false, "invalid command envelope" end
  local local_role = normalize_role(self.network and self.network.role or self.role or self.config.role)

  -- The coordinator sends commands; it does not accept peer control commands.
  -- Local Master actions (for example the redstone update trigger) use their
  -- direct runtime APIs and never arrive through this handler.
  if local_role == normalize_role(constants.roles.MASTER) then
    return false, "MASTER does not accept network commands"
  end
  if normalize_role(message.role) ~= normalize_role(constants.roles.MASTER) then
    return false, "command sender is not MASTER"
  end

  local sender = message.src or message.sender_id or message.node_id
  if sender == nil or tostring(sender):match("^%s*$") then
    return false, "command sender identity missing"
  end
  local expected = self.config.trusted_master_id or self.config.master_node_id
  if expected == nil and type(self.config.comms) == "table" then
    expected = self.config.comms.trusted_master_id
  end
  if expected ~= nil
      and utils.normalize_node_id(sender) ~= utils.normalize_node_id(expected) then
    return false, "command sender does not match trusted master id"
  end
  return true
end

function comms_service:init()
  sanitize_channels(self.config)
  self.uplink = { closed = false, master_downlink_ms = nil, opened_ms = nil, closes = 0, reopens = 0 }
  self.config.comms = comms_lib.sanitize_config(self.config.comms or {})
  self.network = network_lib.init(self.config)
  local normalized_id = utils.normalize_node_id(self.network.id)
  if normalized_id ~= self.network.id then
    utils.log(self.log_prefix, "WARN: normalized node_id to string", "WARN")
    self.network.id = normalized_id
  end
  self.comms = comms_lib.init({
    network = self.network,
    node_id = self.network.id,
    role = self.network.role,
    label = self.label,
    proto_ver = constants.proto_ver,
    log_prefix = self.log_prefix,
    config = self.config.comms or {},
    payload_filter = self.payload_filter,
    -- Wer den Uplink nicht braucht, fuehrt nur MASTER als Peer: die anderen
    -- Nodes hoert er nach dem Schliessen nicht mehr und wuerde jeden davon
    -- als "Peer down" melden (Funk-Hygiene v822).
    -- Mit uplink_close_check (FUEL): alle, solange der Uplink offen ist,
    -- sonst nur MASTER.
    track_peer = (not self.listen_uplink or self.uplink_close_check ~= nil) and function(message)
      if self.listen_uplink and not self.uplink.closed then return true end
      return normalize_role(message.role) == master_role()
    end or nil
  })

  self.comms.on(constants.message_types.STATUS, function(message)
    self:trace_master_rx(message)
    if self.on_status then
      self.on_status(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HEARTBEAT, function(message)
    self:trace_master_rx(message)
    if self.on_heartbeat then
      self.on_heartbeat(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.COMMAND, function(message)
    local authorized, reason = self:_authorize_command(message)
    if not authorized then
      utils.log(self.log_prefix,
        "Command rejected before role handler: " .. tostring(reason)
          .. " src=" .. tostring(message and (message.src or message.sender_id) or "?")
          .. " role=" .. tostring(message and message.role or "?")
          .. " target=" .. tostring(command_target(message) or "?"), "WARN")
      return { ok = false, error = reason, reason_code = "UNAUTHORIZED_COMMAND_SOURCE" }
    end

    -- Remote updates are runtime infrastructure, not role-specific business
    -- logic. Queue them for the single updater coroutine instead of executing
    -- an installer from inside a modem event handler.
    if command_target(message) == constants.command_targets.REMOTE_UPDATE then
      return require("core.remote_update").queue_command({
        message = message,
        log_prefix = self.log_prefix,
        utils = utils,
      })
    end
    if self.on_command then
      return self.on_command(message)
    end
    return { ok = false, error = "command handler missing" }
  end)

  self.comms.on(constants.message_types.ALERT, function(message)
    self:trace_master_rx(message)
    if self.on_alert then
      self.on_alert(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ERROR, function(message)
    self:trace_master_rx(message)
    if self.on_error then
      self.on_error(message)
    elseif self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_DELIVERED, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.ACK_APPLIED, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.HELLO, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)

  self.comms.on(constants.message_types.REGISTER, function(message)
    self:trace_master_rx(message)
    if self.on_message then
      self.on_message(message)
    end
  end)
end

-- opts.no_ack: eine Mitteilung ohne Quittung und ohne Wiederholung -- fuer
-- regelmaessig neu gesendete Inhalte (MASTERs Fuellstand-Relais). Der
-- Empfaenger sieht payload.no_ack und quittiert nicht (core/comms.lua,
-- command_wants_ack); ein aelterer Empfaenger quittiert weiter, das schadet
-- nicht.
function comms_service:send_command(target, command, opts)
  local no_ack = opts and opts.no_ack == true or false
  local payload = { target = target, command = command }
  if no_ack then payload.no_ack = true end
  return self.comms.send(target, constants.message_types.COMMAND, payload, {
    priority = 1,
    require_ack = not no_ack,
    require_applied = not no_ack and opts and (opts.requires_applied or opts.require_applied) or false,
    channel = control_channel(self.config)
  })
end

-- Rundrufe (Status, Heartbeat, Alarm, Hello): MASTER auf dem Downlink
-- (control, 6500), jede andere Rolle auf dem Uplink (status, 6501) --
-- Funk-Hygiene v822, siehe comms_service:handle_event(). Bis v821 lagen
-- Status/Heartbeat/Alarm aller Rollen auf 6501 und Hello auf 6500; jede
-- Node hoerte damit jede Meldung jeder anderen. Aeltere Gegenstellen
-- hoeren beide Kanaele und verstehen beides.
function comms_service:publish_status(payload, opts)
  return self.comms.send(nil, constants.message_types.STATUS, payload, {
    priority = 2,
    require_ack = false,
    channel = self:_broadcast_channel()
  })
end

function comms_service:send_heartbeat(state)
  local payload = { state = state }
  local build = build_info.get()
  if type(build) == "table" and build.manifest_version ~= nil then
    payload.manifest_version = build.manifest_version
  end
  return self.comms.send(nil, constants.message_types.HEARTBEAT, payload, {
    priority = 3,
    require_ack = false,
    channel = self:_broadcast_channel()
  })
end

function comms_service:send_alert(severity, message)
  return self.comms.send(nil, constants.message_types.ALERT, { severity = severity, message = message }, {
    priority = 1,
    require_ack = false,
    channel = self:_broadcast_channel()
  })
end

function comms_service:send_hello(capabilities)
  return self.comms.send(nil, constants.message_types.HELLO, { capabilities = capabilities or {} }, {
    priority = 2,
    require_ack = false,
    channel = self:_broadcast_channel()
  })
end

-- self.comms is only set by init() (see above), but some callers (e.g.
-- nodes/support/runtime.lua's run_event_loop()) invoke handle_event()/
-- tick() directly, outside service_manager's init-before-tick guard.
-- Guarded here as defense-in-depth: a role that forgets to call
-- services:init() before its event loop now fails safe (drops the
-- event) instead of crashing on the first modem_message.
--
-- Real-world logs (2026-09-02, VALVE + FUEL) showed a second instance of
-- the same bug class already fixed for the LOG channel: a modem_message
-- carries no inherent routing -- any open channel on the modem a role's
-- wireless comms uses raises the same "modem_message" event, delivered to
-- every handler regardless of which channel it was meant for. VALVE and
-- FUEL both also run nodes/fuel/redstone_router.lua's own raw
-- SET_VALVE/VALVE_ACK/ROUTE_TEACH_PULSE protocol on constants.channels.VALVE
-- -- on the common single-modem setup that channel is opened on the same
-- modem as control/status, so those messages leaked in here too and were
-- rejected by comms.receive()/validateMessage() as "missing role" (they
-- carry src but no role/payload, never having been meant for this
-- pipeline). Filtering by message.type (as already done for LOG_* above)
-- doesn't scale to every sideband protocol a role might add -- filter by
-- channel instead: only control/status traffic belongs on this pipeline.
--
-- DOWNLINK UND UPLINK (Funk-Hygiene v822). CC:Tweaked stellt eine
-- Funkmeldung jedem Computer zu, der ihren Kanal offen hat; was ankommt,
-- belegt Platz in seiner Ereignis-Warteschlange (256), auch wenn es danach
-- sofort verworfen wird. Bis v821 hatte jede Node control UND status offen
-- und hoerte jede Meldung jeder anderen Node -- auf einer grossen Anlage
-- der Grund fuer verlorene Meldungen. Seit v822:
--   control (6500) = Downlink: MASTER -> alle. Jede Node hoert ihn.
--   status  (6501) = Uplink:   Nodes -> MASTER. Nur, wer die anderen Nodes
--                    braucht (MASTER, FUEL), hoert ihn dauerhaft.
-- Eine Rolle mit listen_uplink=false schliesst den Uplink erst, wenn sie
-- MASTERs Heartbeat oder Status AUF DEM DOWNLINK gehoert hat -- ein MASTER
-- bis v821 sendet beides auf 6501 und bleibt so erreichbar. Hoert sie das
-- UPLINK_REOPEN_MS lang nicht mehr, oeffnet sie den Uplink wieder.
--
-- Seit v823 auch eine Rolle, die den Uplink eigentlich hoert, aber gerade
-- nicht braucht (uplink_close_check, FUEL: alle Ventile antworten auf
-- VALVE_PING). Sie schliesst unter derselben MASTER-Bedingung, oeffnet
-- wieder, sobald die Pruefung nein sagt, und schliesst danach fruehestens
-- nach UPLINK_MIN_OPEN_MS erneut -- ein Ventil, das nur ab und zu eine
-- Runde verpasst, laesst den Kanal nicht flattern. Waehrend der Uplink zu
-- ist, fuehrt sie nur MASTER als Peer; beim Schliessen vergisst sie die
-- uebrigen still (kein "Peer down" fuer Nodes, die sie nicht mehr hoert).
comms_service.UPLINK_REOPEN_MS = 30 * 1000
comms_service.UPLINK_MIN_OPEN_MS = 60 * 1000

-- Nur Heartbeat und Status beweisen einen MASTER ab v822: Kommandos und
-- Hello sendet auch ein aelterer MASTER auf dem Downlink.
local function is_downlink_proof(message_type)
  local types = constants.message_types or {}
  return message_type ~= nil
    and (message_type == types.HEARTBEAT or message_type == types.STATUS)
end

function comms_service:_set_uplink_open(open, reason)
  local status = status_channel(self.config)
  if status == control_channel(self.config) then return false end
  local modem = self.network and self.network.modem
  local method = open and "open" or "close"
  if type(modem) ~= "table" or type(modem[method]) ~= "function" then return false end
  local ok = pcall(modem[method], status)
  if not ok then return false end
  self.uplink.closed = not open
  if open then
    self.uplink.reopens = self.uplink.reopens + 1
    self.uplink.opened_ms = now_ms()
  else
    self.uplink.closes = self.uplink.closes + 1
    if self.listen_uplink and self.comms and type(self.comms.forget_peers) == "function" then
      local master = master_role()
      self.comms.forget_peers(function(_, peer)
        return normalize_role(peer and peer.role) ~= master
      end)
    end
  end
  utils.log(self.log_prefix, ("Uplink-Kanal %s %s: %s"):format(
    tostring(status), open and "wieder offen" or "geschlossen", tostring(reason)), "INFO")
  return true
end

-- Braucht diese Rolle den Uplink gerade? Zweiter Wert: der Grund (fuers Log).
function comms_service:_uplink_wanted()
  local seen = self.uplink.master_downlink_ms
  local age = seen and (now_ms() - seen) or nil
  if age == nil or age < 0 or age > comms_service.UPLINK_REOPEN_MS then
    return true, ("MASTER seit %d s nicht auf dem Downlink gehoert")
      :format(math.floor(comms_service.UPLINK_REOPEN_MS / 1000))
  end
  if not self.listen_uplink then
    return false, "MASTER sendet auf dem Downlink "
      .. tostring(control_channel(self.config)) .. "; die anderen Nodes braucht diese Rolle nicht"
  end
  if type(self.uplink_close_check) ~= "function" then return true, nil end
  local ok, can_close, reason = pcall(self.uplink_close_check)
  if ok and can_close == true then return false, reason or "die Rolle braucht den Uplink gerade nicht" end
  if not ok then return true, "Pruefung fehlgeschlagen: " .. tostring(can_close) end
  return true, reason
end

function comms_service:_check_uplink()
  local wanted, reason = self:_uplink_wanted()
  if wanted then
    if self.uplink.closed then self:_set_uplink_open(true, reason) end
    return
  end
  if self.uplink.closed then return end
  if self.listen_uplink and self.uplink.opened_ms ~= nil then
    local open_for = now_ms() - self.uplink.opened_ms
    if open_for >= 0 and open_for < comms_service.UPLINK_MIN_OPEN_MS then return end
  end
  self:_set_uplink_open(false, reason)
end

function comms_service:_note_downlink(message)
  if type(message) ~= "table" or not is_downlink_proof(message.type) then return end
  if normalize_role(message.role) ~= master_role() then return end
  self.uplink.master_downlink_ms = now_ms()
  if not self.listen_uplink or self.uplink_close_check ~= nil then self:_check_uplink() end
end

function comms_service:get_uplink_state()
  return {
    listen = self.listen_uplink,
    closed = self.uplink.closed,
    master_downlink_ms = self.uplink.master_downlink_ms,
    opened_ms = self.uplink.opened_ms,
    closes = self.uplink.closes,
    reopens = self.uplink.reopens,
  }
end

function comms_service:handle_event(event)
  if not self.comms then return end
  if event[1] == "modem_message" then
    local channel, message = event[3], event[5]
    if utils.handle_remote_log_message and utils.handle_remote_log_message(message, channel) then
      return true
    end
    local control = control_channel(self.config)
    if channel ~= control and channel ~= status_channel(self.config) then
      return true
    end
    if channel == control then self:_note_downlink(message) end
    self.comms.receive(message)
  end
end

function comms_service:tick()
  if not self.comms then return end
  if utils.flush_remote_logs then utils.flush_remote_logs() end
  self:_check_uplink()
  self.comms.tick()
end

function comms_service:get_peers()
  return self.comms.get_peer_state()
end

function comms_service:get_diagnostics()
  return self.comms.get_diagnostics()
end

function comms_service:consume_timeouts()
  return self.comms.consume_timeouts()
end

function comms_service:is_master_reachable()
  local peers = self:get_peers() or {}
  for _, data in pairs(peers) do
    if data.role == constants.roles.MASTER then
      return not data.down
    end
  end
  return false
end

return comms_service
