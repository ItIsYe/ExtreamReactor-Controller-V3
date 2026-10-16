local utils = require("core.utils")
local alerts_lib = require("core.alerts")
local rules_lib = require("core.alert_rules")

local alert_service = {}

local severity_level = {
  INFO = "INFO",
  WARN = "WARN",
  CRITICAL = "ERROR"
}

local state_defaults = {
  mutes = {
    rules = {},
    nodes = {},
    -- je Eintrag (Schluessel einer Ursache), Seite MELDUNGEN "SPERREN"
    keys = {}
  }
}

local function now_ms()
  return os.epoch("utc")
end

local function normalize_mutes(state)
  state.mutes = type(state.mutes) == "table" and state.mutes or { rules = {}, nodes = {} }
  state.mutes.rules = type(state.mutes.rules) == "table" and state.mutes.rules or {}
  state.mutes.nodes = type(state.mutes.nodes) == "table" and state.mutes.nodes or {}
  state.mutes.keys = type(state.mutes.keys) == "table" and state.mutes.keys or {}
end

local function is_expired(entry, now)
  if not entry then
    return true
  end
  if type(entry) == "number" then
    return entry <= now
  end
  return type(entry.until_ts or entry["until"]) ~= "number" or (entry.until_ts or entry["until"]) <= now
end

local function build_source_key(source)
  if type(source) ~= "table" then
    return "unknown"
  end
  local parts = {
    tostring(source.node_id or "unknown"),
    tostring(source.role or "unknown"),
    tostring(source.device_id or "")
  }
  return table.concat(parts, "|")
end

local function build_alert_key(entry)
  if type(entry) ~= "table" then return nil end
  if entry.key then return entry.key end
  local code = tostring(entry.code or "ALERT")
  return build_source_key(entry.source) .. "|" .. code
end

function alert_service.new(opts)
  opts = opts or {}
  local config = opts.config or {}
  -- Automatische Quittung gegangener Stoerungen und Flatterschutz (v834,
  -- siehe core/alerts.lua): Minuten in der MASTER-Config.
  local alerts = alerts_lib.new({
    info_ttl_s = config.alert_info_ttl or 10,
    history_size = config.alert_history_size or 100,
    auto_ack_s = (tonumber(config.alarm_auto_ack_min) or 30) * 60,
    reack_window_s = (tonumber(config.alarm_reack_window_min) or 30) * 60,
  })
  local state_path = config.alert_state_path or "/xreactor_config/alerts_state.lua"
  local state = utils.load_config(state_path, state_defaults)
  normalize_mutes(state)
  local now = now_ms()
  for key, entry in pairs(state.mutes.rules) do
    if is_expired(entry, now) then
      state.mutes.rules[key] = nil
    end
  end
  for key, entry in pairs(state.mutes.nodes) do
    if is_expired(entry, now) then
      state.mutes.nodes[key] = nil
    end
  end
  for key, entry in pairs(state.mutes.keys) do
    if is_expired(entry, now) then
      state.mutes.keys[key] = nil
    end
  end
  -- Optionale akustische Alarmierung (Feature, 2026-07-01): standardmaessig
  -- aktiv (opt-out via config.enable_speaker_alarm = false statt opt-in),
  -- da das Modul selbst komplett harmlos ist wenn kein Speaker angeschlossen
  -- ist (findet einfach keinen und tut nichts). require() ist pcall-
  -- geschuetzt fuer den Fall, dass optional/speaker_alarm.lua auf einem
  -- Node fehlt (z.B. altes Manifest vor diesem Feature).
  local speaker_alarm = nil
  if config.enable_speaker_alarm ~= false then
    local ok_spk_mod, spk_mod = pcall(require, "optional.speaker_alarm")
    if ok_spk_mod then
      local ok_spk_inst, spk_inst = pcall(spk_mod.new, {})
      if ok_spk_inst then speaker_alarm = spk_inst end
    end
  end
  local self = {
    log_prefix = opts.log_prefix or "ALERT",
    config = config,
    nodes = opts.nodes,
    power_target = opts.power_target,
    alerts = alerts,
    rules = rules_lib.new(config),
    last_eval = 0,
    recovery_notice = opts.recovery_notice,
    state_path = state_path,
    state = state,
    clear_pending = {},
    -- Gesperrte Schluessel, deren Unterdrueckung schon im Verlauf steht --
    -- frueher kam alle 6 s je gesperrter Meldung ein Eintrag dazu.
    muted_noted = {},
    last_eval_duration_ms = 0,
    last_eval_ts = 0,
    muted_last = 0,
    speaker_alarm = speaker_alarm
  }
  return setmetatable(self, { __index = alert_service })
end

function alert_service:log_alert(alert, event)
  local level = severity_level[alert.severity] or "INFO"
  local source = alert.source or {}
  local node_id = tostring(source.node_id or source.role or "SYSTEM")
  local code = tostring(alert.code or (alert.details and alert.details.code) or "ALERT")
  local msg = tostring(alert.message or "")
  local event_text = event and (" event=" .. tostring(event)) or ""
  local message = string.format("severity=%s code=%s node=%s%s msg=%s", alert.severity or "INFO", code, node_id, event_text, msg)
  utils.log(self.log_prefix, message, level)
end

function alert_service:log_mute(kind, key, until_ts)
  local until_label = until_ts and os.date("!%H:%M:%S", math.floor(until_ts / 1000)) or "cleared"
  local node_id = (kind == "mute_node" or kind == "unmute_node") and tostring(key) or "SYSTEM"
  local code = (kind == "mute_rule" or kind == "unmute_rule") and tostring(key) or "NODE_MUTE"
  local msg = string.format("%s until=%s", kind, tostring(until_label))
  local message = string.format("severity=INFO code=%s node=%s msg=%s", code, node_id, msg)
  utils.log(self.log_prefix, message, "INFO")
end

function alert_service:save_state()
  utils.write_config(self.state_path, self.state)
end

function alert_service:_is_muted(entry, now)
  if not entry or type(entry) ~= "table" then
    return nil
  end
  local code = entry.code
  local source = entry.source or {}
  local node_id = source.node_id
  local function until_of(e) return type(e) == "table" and (e.until_ts or e["until"]) or e end
  local key = build_alert_key(entry)
  local key_entry = key and self.state.mutes.keys and self.state.mutes.keys[key] or nil
  if key_entry and not is_expired(key_entry, now) then
    return "key", key, until_of(key_entry)
  end
  local rule_entry = code and self.state.mutes.rules[code] or nil
  if rule_entry and not is_expired(rule_entry, now) then
    return "rule", code, until_of(rule_entry)
  end
  if rule_entry then
    self.state.mutes.rules[code] = nil
  end
  if node_id then
    local node_entry = self.state.mutes.nodes[node_id]
    if node_entry and not is_expired(node_entry, now) then
      return "node", node_id, until_of(node_entry)
    end
    if node_entry then
      self.state.mutes.nodes[node_id] = nil
    end
  end
  return nil
end

function alert_service:_clear_alert(key, now)
  if not key then return end
  local active = self.alerts.active_by_key and self.alerts.active_by_key[key] or nil
  if not active then
    self.clear_pending[key] = nil
    return
  end
  local grace_ms = math.max(0, tonumber(self.config.alert_clear_grace_s or self.config.alert_clear_debounce_s or 3) or 0) * 1000
  if grace_ms > 0 and active.severity ~= "INFO" then
    local first_seen = self.clear_pending[key]
    if not first_seen then
      self.clear_pending[key] = now
      return
    end
    if now - first_seen < grace_ms then
      return
    end
  end
  self.clear_pending[key] = nil
  local cleared = self.alerts:resolve(key)
  if cleared then
    self:log_alert(cleared, "clear")
  end
end

function alert_service:tick()
  local now = now_ms()
  local interval = (self.config.alert_eval_interval or 1) * 1000
  if now - self.last_eval < interval then
    return
  end
  local eval_start = now
  self.last_eval = now
  local mutes_changed = false
  for key, entry in pairs(self.state.mutes.rules or {}) do
    if is_expired(entry, now) then
      self.state.mutes.rules[key] = nil
      mutes_changed = true
    end
  end
  for key, entry in pairs(self.state.mutes.nodes or {}) do
    if is_expired(entry, now) then
      self.state.mutes.nodes[key] = nil
      mutes_changed = true
    end
  end
  for key, entry in pairs(self.state.mutes.keys or {}) do
    if is_expired(entry, now) then
      self.state.mutes.keys[key] = nil
      mutes_changed = true
    end
  end
  if mutes_changed then
    self:save_state()
  end
  if self.recovery_notice and self.recovery_notice.active_until and now > self.recovery_notice.active_until then
    self.recovery_notice.active = false
  end
  local alerts, clears = self.rules:evaluate({
    nodes = self.nodes,
    config = self.config,
    power_target = type(self.power_target) == "function" and self.power_target() or self.power_target,
    recovery_notice = self.recovery_notice,
    now = now
  })
  local muted_count = 0
  for _, entry in ipairs(alerts or {}) do
    local key = build_alert_key(entry)
    if key then self.clear_pending[key] = nil end
  end
  for _, key in ipairs(clears or {}) do
    self:_clear_alert(key, now)
  end
  -- Wartende Aufloesungen nach der Schonfrist nachholen (v837). Die Regeln
  -- melden "ist weg" genau EINMAL (core/alert_rules.lua should_raise);
  -- _clear_alert() merkt sich dabei nur den Zeitpunkt und loest erst nach
  -- alert_clear_grace_s auf -- ein zweiter Aufruf kam aber nie. Damit ging
  -- keine Meldung jemals (schon vor v833): keine Stoerung wurde zu "WEG",
  -- keine Warnung verschwand, die automatische Quittung griff nie, und die
  -- MASTER-Ampel blieb nach jedem Ausfall rot. Kommt die Ursache in der
  -- Schonfrist wieder, hat raise() oben die Wartemarke schon geloescht.
  for key in pairs(self.clear_pending) do
    self:_clear_alert(key, now)
  end
  for _, entry in ipairs(alerts or {}) do
    local muted_kind, _, muted_until = self:_is_muted(entry, now)
    local key = build_alert_key(entry)
    if muted_kind then
      muted_count = muted_count + 1
      -- Einmal je Sperre in den Verlauf, nicht bei jeder Auffrischung.
      local noted = key and self.muted_noted[key] == (muted_until or true)
      if key then self.muted_noted[key] = muted_until or true end
      if self.config.alert_log_muted_events and not noted then
        local muted_entry = {
          severity = "INFO",
          scope = entry.scope,
          source = entry.source,
          code = entry.code,
          title = "Alert muted",
          message = string.format("%s muted (%s)", tostring(entry.title or entry.code or "Alert"), tostring(muted_kind)),
          details = { muted = muted_kind, ts = now }
        }
        self.alerts:record_muted(muted_entry)
        self:log_alert(muted_entry, "muted")
      end
    else
      if key then self.muted_noted[key] = nil end
      local result = self.alerts:raise(entry)
      if result and result.log and result.alert then
        self:log_alert(result.alert, result.event)
      end
    end
  end
  local expired, auto_acked = self.alerts:tick(now)
  for _, alert in ipairs(expired or {}) do
    self:log_alert(alert, "expired")
  end
  for _, alert in ipairs(auto_acked or {}) do
    self:log_alert(alert, "auto_ack")
  end
  self.muted_last = muted_count
  self.last_eval_duration_ms = now_ms() - eval_start
  self.last_eval_ts = eval_start

  -- Optionale akustische Alarmierung (Feature, 2026-07-01, erweitert
  -- 2026-07-02 um Entwarnungs-Ton + zusaetzliche Ereignis-Sounds): siehe
  -- xreactor/optional/speaker_alarm.lua. Vollstaendig fehlerisoliert —
  -- fehlt der Speaker oder ist opts.speaker_alarm nicht gesetzt, passiert
  -- hier einfach nichts.
  -- Hupe (v834): nur solange eine Stoerung ANSTEHT und noch NICHT
  -- quittiert ist -- Quittieren stellt sie ab. Bis v833 lief sie alle 8 s,
  -- solange irgendeine Stoerung stand, quittiert oder nicht.
  if self.speaker_alarm then
    local counts = self:get_counts()
    local critical_active = (counts.CRITICAL or 0) > 0
    if (counts.UNACKED_ACTIVE_CRITICAL or 0) > 0 then
      pcall(self.speaker_alarm.play, "alarm")
    end
    if not critical_active and self.last_critical_active == true then
      -- Uebergang von "war aktiv" zu "jetzt nicht mehr aktiv" — Entwarnung
      -- nur EINMAL beim Uebergang spielen, nicht dauerhaft solange kein
      -- Alarm aktiv ist (das waere sinnlos haeufig).
      pcall(self.speaker_alarm.play, "clear")
    end
    self.last_critical_active = critical_active

    -- node_offline / safe_mode: einmal je Auftreten (Eintrag + Zaehler --
    -- ein Eintrag bleibt beim Wiederkommen derselbe), und nur, solange er
    -- ansteht und nicht quittiert ist.
    self.seen_offline_ids = self.seen_offline_ids or {}
    self.seen_safe_ids = self.seen_safe_ids or {}
    local active = self.alerts:get_active()
    local still_offline, still_safe = {}, {}
    for _, alert in ipairs(active) do
      local occurrence = tostring(alert.id) .. "#" .. tostring(alert.count or 1)
      local sounding = alert.active ~= false and not alert.acknowledged
      if alert.code == "NODE_COMMS_DOWN" then
        still_offline[occurrence] = true
        if sounding and not self.seen_offline_ids[occurrence] then
          pcall(self.speaker_alarm.play, "node_offline")
        end
      elseif alert.code == "RT_SAFE_MODE" or alert.code == "RT_EMERGENCY" then
        still_safe[occurrence] = true
        if sounding and not self.seen_safe_ids[occurrence] then
          pcall(self.speaker_alarm.play, "safe_mode")
        end
      end
    end
    self.seen_offline_ids = still_offline
    self.seen_safe_ids = still_safe
  end
end

-- Die Meldungsliste: anstehende Eintraege und gegangene, noch nicht
-- quittierte Stoerungen (alert.active sagt, welches). Wiederkehr steht in
-- alert.count, nicht mehr in einem eigenen Zustand.
function alert_service:get_active()
  return self.alerts:get_active()
end

function alert_service:get_history()
  return self.alerts:get_history()
end

function alert_service:get_history_filtered(opts)
  return self.alerts:get_history_filtered(opts)
end

function alert_service:get_counts()
  return self.alerts:get_counts_by_severity()
end

function alert_service:get_summary()
  return self.alerts:render_summary()
end

function alert_service:get_top_critical(limit)
  local list = {}
  local max = limit or 3
  for _, alert in ipairs(self.alerts:get_active()) do
    if alert.severity == "CRITICAL" and alert.active ~= false then
      table.insert(list, alert)
      if #list >= max then
        break
      end
    end
  end
  return list
end

-- Quittieren ist einseitig: ein zweiter Aufruf aendert nichts.
function alert_service:ack(id)
  local ok, alert = self.alerts:ack(id)
  if ok and alert then
    self:log_alert(alert, "ack")
  end
  return ok
end

function alert_service:ack_all()
  local changed = self.alerts:ack_all(true)
  for _, alert in ipairs(changed or {}) do
    self:log_alert(alert, "ack_all")
  end
end

function alert_service:ack_visible(ids)
  local changed = self.alerts:set_ack_for_ids(ids, true)
  for _, alert in ipairs(changed or {}) do
    self:log_alert(alert, "ack_visible")
  end
end

function alert_service:unack(id)
  local ok, alert = self.alerts:set_ack(id, false)
  if ok and alert then
    self:log_alert(alert, "unack")
  end
  return ok
end

function alert_service:mute_rule(code, minutes)
  if not code then
    return false
  end
  local duration = math.max(1, tonumber(minutes) or (self.config.alert_mute_default_minutes or 10))
  local until_ts = now_ms() + duration * 60 * 1000
  self.state.mutes.rules[code] = { until_ts = until_ts, minutes = duration }
  self:save_state()
  self:log_mute("mute_rule", code, until_ts)
  return true
end

function alert_service:unmute_rule(code)
  if not code then
    return false
  end
  if self.state.mutes.rules[code] then
    self.state.mutes.rules[code] = nil
    self:save_state()
    self:log_mute("unmute_rule", code, nil)
  end
  return true
end

function alert_service:mute_node(node_id, minutes)
  if not node_id then
    return false
  end
  local duration = math.max(1, tonumber(minutes) or (self.config.alert_mute_default_minutes or 10))
  local until_ts = now_ms() + duration * 60 * 1000
  self.state.mutes.nodes[node_id] = { until_ts = until_ts, minutes = duration }
  self:save_state()
  self:log_mute("mute_node", node_id, until_ts)
  return true
end

function alert_service:unmute_node(node_id)
  if not node_id then
    return false
  end
  if self.state.mutes.nodes[node_id] then
    self.state.mutes.nodes[node_id] = nil
    self:save_state()
    self:log_mute("unmute_node", node_id, nil)
  end
  return true
end

-- Einen Eintrag sperren (Seite MELDUNGEN): er verschwindet aus der Liste,
-- und dieselbe Ursache meldet sich `minutes` lang nicht. Steht sie danach
-- noch an, kommt sie wieder.
function alert_service:mute_key(key, minutes)
  if not key then return false end
  local duration = math.max(1, tonumber(minutes) or (self.config.alert_mute_default_minutes or 10))
  local until_ts = now_ms() + duration * 60 * 1000
  self.state.mutes.keys = self.state.mutes.keys or {}
  self.state.mutes.keys[key] = { until_ts = until_ts, minutes = duration }
  self.alerts:drop(key)
  self:save_state()
  self:log_mute("mute_key", key, until_ts)
  return true
end

function alert_service:unmute_keys()
  local had = next(self.state.mutes.keys or {}) ~= nil
  self.state.mutes.keys = {}
  self.muted_noted = {}
  if had then
    self:save_state()
    self:log_mute("unmute_keys", "ALL", nil)
  end
  return true
end

-- Eine Node vergessen (abgebauter Rechner): ihre Eintraege und der Zustand
-- ihrer Regeln verschwinden. Meldet sie sich wieder, beginnt alles neu.
function alert_service:forget_node(node_id)
  if not node_id then return false end
  local removed = self.alerts:forget_node(node_id)
  if self.rules and type(self.rules.forget_node) == "function" then self.rules:forget_node(node_id) end
  utils.log(self.log_prefix, string.format("severity=INFO code=NODE_FORGOTTEN node=%s msg=%d Eintraege entfernt",
    tostring(node_id), #(removed or {})), "INFO")
  return true
end

function alert_service:get_mutes()
  return self.state.mutes
end

function alert_service:get_metrics()
  local active = self.alerts:get_active() or {}
  local counts_by_role = {}
  local counts_by_node = {}
  for _, alert in ipairs(active) do
    local source = alert.source or {}
    local role = source.role or "UNKNOWN"
    local node_id = source.node_id or "UNKNOWN"
    counts_by_role[role] = (counts_by_role[role] or 0) + 1
    counts_by_node[node_id] = (counts_by_node[node_id] or 0) + 1
  end
  local muted_rules = 0
  local muted_nodes = 0
  for _ in pairs(self.state.mutes.rules or {}) do
    muted_rules = muted_rules + 1
  end
  for _ in pairs(self.state.mutes.nodes or {}) do
    muted_nodes = muted_nodes + 1
  end
  return {
    counts_by_role = counts_by_role,
    counts_by_node = counts_by_node,
    last_eval_ts = self.last_eval_ts,
    eval_duration_ms = self.last_eval_duration_ms,
    muted_counts = {
      rules = muted_rules,
      nodes = muted_nodes,
      suppressed = self.muted_last or 0
    }
  }
end

return alert_service
