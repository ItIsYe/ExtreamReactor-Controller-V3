-- core/alerts.lua -- MASTERs Meldungsliste.
--
-- Neu geschrieben (v834, Betreiber 2026-10-16: "Ich kann die Meldungen
-- nicht quittieren, oder die kommen so schnell wieder, dass es nichts
-- bringt"). Bis v833 hing die Quittung an der einzelnen Meldung: ging die
-- Bedingung ein paar Sekunden weg, wurde die Meldung geloescht, kam sie
-- zurueck, war sie ein neuer Eintrag ohne Quittung. Dazu hob ein zweiter
-- Tipp die Quittung wieder auf, und eine Hochstufung setzte sie zurueck.
--
-- Jetzt gilt (wie bei einer SPS):
--   - Je Ursache (Schluessel: Regel + Node + Geraet) genau EIN Eintrag.
--     Kommt die Ursache wieder, ist es derselbe Eintrag; count zaehlt mit.
--   - Eine Stoerung (CRITICAL) bleibt nach dem Gehen stehen, bis sie
--     quittiert ist ("gegangen, nicht quittiert"). Kommt sie in
--     auto_ack_s nicht wieder, wird sie automatisch quittiert
--     (Betreibervorgabe: "bis zur Quittierung stehen lassen, oder wenn der
--     Fehler innerhalb von einer Zeit X nicht wieder auftritt, automatisch
--     quittieren").
--   - Warnungen und Meldungen verschwinden, sobald sie gehen.
--   - Flatterschutz: kommt eine quittierte Ursache innerhalb von
--     reack_window_s wieder, kommt sie quittiert zurueck -- es sei denn,
--     sie ist schlimmer geworden.
--   - Quittieren ist einseitig, ein zweiter Tipp nimmt nichts zurueck.
--
-- Zaehler (get_counts_by_severity): CRITICAL/WARN/INFO zaehlen nur, was
-- gerade ANSTEHT (Ampel, Kopfzeilen). Dazu UNACKED, UNACKED_CRITICAL und
-- GONE_UNACKED_CRITICAL (gegangene, noch nicht quittierte Stoerungen --
-- die MASTER-Ampel blinkt dafuer).
--
-- Verlauf: je Ereignis ein Eintrag (event = raise/again/severity/clear/
-- ack/auto_ack/muted, event_ts = wann), nicht bei jeder Auffrischung.

local utils = require("core.utils")

local alerts = {}

local severity_rank = { CRITICAL = 1, WARN = 2, INFO = 3 }

local function now_ms()
  return os.epoch("utc")
end

local function normalize_severity(value)
  local key = tostring(value or "INFO"):upper()
  if key == "WARNING" then key = "WARN" end
  if severity_rank[key] then return key end
  return "INFO"
end

local function normalize_scope(value)
  local key = tostring(value or "SYSTEM"):upper()
  if key == "SYSTEM" or key == "NODE" or key == "DEVICE" then return key end
  return "SYSTEM"
end

local function build_source_key(source)
  if type(source) ~= "table" then return "unknown" end
  return table.concat({
    tostring(source.node_id or "unknown"),
    tostring(source.role or "unknown"),
    tostring(source.device_id or ""),
  }, "|")
end

local function build_key(entry)
  if entry.key then return entry.key end
  return build_source_key(entry.source) .. "|" .. tostring(entry.code or "ALERT")
end

function alerts.new(opts)
  opts = opts or {}
  local self = {
    info_ttl_s = tonumber(opts.info_ttl_s) or 10,
    history_size = tonumber(opts.history_size) or 100,
    auto_ack_s = tonumber(opts.auto_ack_s) or 1800,
    reack_window_s = tonumber(opts.reack_window_s) or 1800,
    seq = 0,
    -- Alle Eintraege der Liste (anstehend ODER gegangen-unquittiert). Der
    -- Name bleibt aus Kompatibilitaet (services/alert_service.lua liest ihn).
    active_by_key = {},
    active_by_id = {},
    -- Erledigte Ursachen (quittiert und gegangen), fuer den Flatterschutz:
    -- key -> { count, acknowledged, ack_ts, severity, gone_ts, node_id }
    recent = {},
    history = {},
    active_cache = nil,
    counts_cache = nil,
    summary_cache = nil,
  }
  return setmetatable(self, { __index = alerts })
end

function alerts:_mark_dirty()
  self.active_cache = nil
  self.counts_cache = nil
  self.summary_cache = nil
end

function alerts:_ensure_details(entry)
  local details = entry.details
  if type(details) ~= "table" then details = { value = details } end
  if entry.code and details.code == nil then details.code = entry.code end
  return details
end

function alerts:_push_history(alert, event, ts)
  local snapshot = utils.deep_copy(alert)
  snapshot.event = event
  snapshot.event_ts = ts or now_ms()
  table.insert(self.history, 1, snapshot)
  while #self.history > self.history_size do table.remove(self.history) end
end

-- Eintrag aus der Liste nehmen und fuer den Flatterschutz merken.
function alerts:_retire(key, alert, now)
  self.active_by_key[key] = nil
  self.active_by_id[alert.id] = nil
  self.recent[key] = {
    count = alert.count, acknowledged = alert.acknowledged, ack_ts = alert.ack_ts,
    severity = alert.severity, gone_ts = alert.ts_gone or now,
    node_id = alert.source and alert.source.node_id,
  }
  self:_mark_dirty()
end

-- raise(entry): die Ursache steht an (oder wird aufgefrischt).
-- result.event: "raise" (neu), "again" (wiedergekommen), "severity"
-- (Klasse geaendert), nil (nur aufgefrischt). result.log sagt, ob das ins
-- Protokoll gehoert.
function alerts:raise(entry)
  if type(entry) ~= "table" then return nil end
  local key = build_key(entry)
  local ts = entry.ts or now_ms()
  local severity = normalize_severity(entry.severity)
  local result = { log = false, alert = nil, event = nil, severity_changed = false }
  local existing = self.active_by_key[key]

  if existing then
    local event = nil
    if not existing.active then
      existing.active = true
      existing.count = (existing.count or 1) + 1
      existing.ts_came = ts
      existing.ts_gone = nil
      event = "again"
    end
    if existing.severity ~= severity then
      if severity_rank[severity] < severity_rank[existing.severity] and existing.acknowledged then
        -- Schlimmer geworden: die alte Quittung gilt nicht mehr.
        existing.acknowledged = nil
        existing.ack_ts = nil
        existing.ack_auto = nil
      end
      existing.severity = severity
      result.severity_changed = true
      event = event or "severity"
    end
    existing.ts_last = ts
    existing.title = tostring(entry.title or existing.title or "Meldung")
    existing.message = tostring(entry.message or "")
    if entry.code then existing.code = tostring(entry.code) end
    existing.details = self:_ensure_details(entry)
    if event then
      result.log = true
      result.event = event
      self:_push_history(existing, event, ts)
    end
    result.alert = existing
    self:_mark_dirty()
    return result
  end

  -- Ist die Ursache erst kuerzlich gegangen, ist das eine Wiederkehr: der
  -- Zaehler laeuft weiter, und eine Quittung gilt weiter -- ausser es ist
  -- jetzt schlimmer.
  local recent = self.recent[key]
  if recent and (ts - (recent.gone_ts or 0)) > self.reack_window_s * 1000 then recent = nil end
  self.recent[key] = nil

  self.seq = self.seq + 1
  local alert = {
    id = string.format("ALERT-%d-%d", ts, self.seq),
    key = key,
    ts_first = ts,
    ts_last = ts,
    ts_came = ts,
    severity = severity,
    code = entry.code and tostring(entry.code) or nil,
    scope = normalize_scope(entry.scope),
    source = type(entry.source) == "table" and entry.source or {},
    title = tostring(entry.title or "Meldung"),
    message = tostring(entry.message or ""),
    details = self:_ensure_details(entry),
    active = true,
    count = 1,
  }
  local event = "raise"
  if recent then
    alert.count = (recent.count or 1) + 1
    event = "again"
    local worse = severity_rank[severity] < severity_rank[recent.severity or severity]
    if recent.acknowledged and not worse then
      alert.acknowledged = true
      alert.ack_ts = recent.ack_ts
    end
  end
  self.active_by_key[key] = alert
  self.active_by_id[alert.id] = alert
  self:_push_history(alert, event, ts)
  self:_mark_dirty()
  result.alert = alert
  result.log = true
  result.event = event
  return result
end

-- resolve(key): die Ursache ist weg. Eine unquittierte Stoerung bleibt als
-- "gegangen" stehen, alles andere verlaesst die Liste.
function alerts:resolve(key)
  if not key then return false end
  local alert = self.active_by_key[key]
  if not alert or not alert.active then return false end
  local now = now_ms()
  alert.active = false
  alert.ts_gone = now
  alert.resolved_ts = now
  self:_push_history(alert, "clear", now)
  if alert.severity ~= "CRITICAL" or alert.acknowledged then
    self:_retire(key, alert, now)
  else
    self:_mark_dirty()
  end
  return alert
end

-- set_ack(id, value): value ~= false quittiert. false nimmt eine Quittung
-- ausdruecklich zurueck (nur fuer services/alert_service.lua's unack);
-- nil quittiert ebenfalls -- frueher schaltete nil hin und her, und ein
-- zweiter Tipp auf der Seite "Logs" hob die Quittung wieder auf.
function alerts:set_ack(id, value, opts)
  if not id then return false end
  local alert = self.active_by_id[id]
  if not alert then return false end
  local now = now_ms()
  if value == false then
    if not alert.acknowledged then return false end
    alert.acknowledged = nil
    alert.ack_ts = nil
    alert.ack_auto = nil
    self:_mark_dirty()
    return true, alert
  end
  if alert.acknowledged then return false end
  alert.acknowledged = true
  alert.ack_ts = now
  alert.ack_auto = (opts and opts.auto) and true or nil
  self:_push_history(alert, alert.ack_auto and "auto_ack" or "ack", now)
  if not alert.active then
    self:_retire(alert.key, alert, now)
  else
    self:_mark_dirty()
  end
  return true, alert
end

function alerts:ack(id)
  return self:set_ack(id, true)
end

function alerts:set_ack_for_ids(ids, value)
  local changed = {}
  for _, id in ipairs(ids or {}) do
    local ok, alert = self:set_ack(id, value)
    if ok and alert then changed[#changed + 1] = alert end
  end
  return changed
end

function alerts:ack_all(value)
  local ids = {}
  for _, alert in pairs(self.active_by_key) do ids[#ids + 1] = alert.id end
  table.sort(ids)
  local wanted = true
  if value == false then wanted = false end
  return self:set_ack_for_ids(ids, wanted)
end

-- Einen Eintrag ohne Quittung und ohne Flatterschutz entfernen (Sperre:
-- services/alert_service.lua mute_key).
function alerts:drop(key)
  local alert = key and self.active_by_key[key]
  if not alert then return false end
  self.active_by_key[key] = nil
  self.active_by_id[alert.id] = nil
  self.recent[key] = nil
  self:_mark_dirty()
  return true
end

-- Alles zu einer Node vergessen (abgebaute Rechner, master "Node vergessen").
function alerts:forget_node(node_id)
  local removed = {}
  for key, alert in pairs(self.active_by_key) do
    if alert.source and tostring(alert.source.node_id) == tostring(node_id) then
      self.active_by_key[key] = nil
      self.active_by_id[alert.id] = nil
      removed[#removed + 1] = alert
    end
  end
  for key, entry in pairs(self.recent) do
    if tostring(entry.node_id) == tostring(node_id) then self.recent[key] = nil end
  end
  if #removed > 0 then self:_mark_dirty() end
  return removed
end

function alerts:record_muted(entry)
  if type(entry) ~= "table" then return end
  self.seq = self.seq + 1
  local ts = entry.ts or now_ms()
  local snapshot = {
    id = string.format("MUTED-%d-%d", ts, self.seq),
    ts_first = ts,
    ts_last = ts,
    severity = normalize_severity(entry.severity or "INFO"),
    code = entry.code and tostring(entry.code) or nil,
    scope = normalize_scope(entry.scope),
    source = type(entry.source) == "table" and entry.source or {},
    title = tostring(entry.title or "Gesperrte Meldung"),
    message = tostring(entry.message or ""),
    details = self:_ensure_details(entry),
    muted = true,
  }
  self:_push_history(snapshot, "muted", ts)
end

-- tick(now): Meldungen (INFO) laufen nach info_ttl_s ohne Auffrischung ab;
-- gegangene Stoerungen werden nach auto_ack_s automatisch quittiert; der
-- Flatterschutz vergisst Ursachen nach reack_window_s.
-- Gibt (abgelaufen, automatisch_quittiert) zurueck.
function alerts:tick(ts)
  local now = ts or now_ms()
  local expired, auto_acked = {}, {}
  if self.info_ttl_s and self.info_ttl_s > 0 then
    local ttl_ms = self.info_ttl_s * 1000
    for key, alert in pairs(self.active_by_key) do
      if alert.severity == "INFO" and now - (alert.ts_last or 0) >= ttl_ms then
        self.active_by_key[key] = nil
        self.active_by_id[alert.id] = nil
        expired[#expired + 1] = alert
        self:_mark_dirty()
      end
    end
  end
  if self.auto_ack_s and self.auto_ack_s > 0 then
    local due = {}
    for _, alert in pairs(self.active_by_key) do
      if not alert.active and not alert.acknowledged and now - (alert.ts_gone or now) >= self.auto_ack_s * 1000 then
        due[#due + 1] = alert.id
      end
    end
    table.sort(due)
    for _, id in ipairs(due) do
      local ok, alert = self:set_ack(id, true, { auto = true })
      if ok then auto_acked[#auto_acked + 1] = alert end
    end
  end
  for key, entry in pairs(self.recent) do
    if now - (entry.gone_ts or 0) > self.reack_window_s * 1000 then self.recent[key] = nil end
  end
  return expired, auto_acked
end

-- Die Liste: zuerst nach Klasse, dann Unquittiertes vor Quittiertem, dann
-- Anstehendes vor Gegangenem, dann das Neueste zuerst.
function alerts:get_active()
  if not self.active_cache then
    local list = {}
    for _, alert in pairs(self.active_by_key) do list[#list + 1] = alert end
    table.sort(list, function(a, b)
      local ar, br = severity_rank[a.severity] or 99, severity_rank[b.severity] or 99
      if ar ~= br then return ar < br end
      local aa, ba = a.acknowledged and 1 or 0, b.acknowledged and 1 or 0
      if aa ~= ba then return aa < ba end
      local ai, bi = a.active and 0 or 1, b.active and 0 or 1
      if ai ~= bi then return ai < bi end
      if (a.ts_came or 0) ~= (b.ts_came or 0) then return (a.ts_came or 0) > (b.ts_came or 0) end
      return tostring(a.id) < tostring(b.id)
    end)
    self.active_cache = list
  end
  return self.active_cache
end

function alerts:get_history()
  return self.history
end

-- Zeitgefilterter Verlauf; opts.since_ms/opts.until_ms sind absolute
-- os.epoch("utc")-Zeitstempel, beide optional. Massgeblich ist die Zeit des
-- Ereignisses (event_ts).
function alerts:get_history_filtered(opts)
  opts = opts or {}
  local since_ms = tonumber(opts.since_ms)
  local until_ms = tonumber(opts.until_ms)
  if not since_ms and not until_ms then return self.history end
  local out = {}
  for _, entry in ipairs(self.history) do
    local ts = tonumber(entry.event_ts) or tonumber(entry.resolved_ts) or tonumber(entry.ts_last)
      or tonumber(entry.ts_first) or 0
    if (not since_ms or ts >= since_ms) and (not until_ms or ts <= until_ms) then
      out[#out + 1] = entry
    end
  end
  return out
end

function alerts:get_counts_by_severity()
  if not self.counts_cache then
    local counts = { INFO = 0, WARN = 0, CRITICAL = 0, UNACKED = 0, UNACKED_CRITICAL = 0,
      UNACKED_ACTIVE_CRITICAL = 0, GONE_UNACKED_CRITICAL = 0 }
    for _, alert in pairs(self.active_by_key) do
      if alert.active then counts[alert.severity] = (counts[alert.severity] or 0) + 1 end
      if not alert.acknowledged then
        counts.UNACKED = counts.UNACKED + 1
        if alert.severity == "CRITICAL" then
          counts.UNACKED_CRITICAL = counts.UNACKED_CRITICAL + 1
          if alert.active then
            counts.UNACKED_ACTIVE_CRITICAL = counts.UNACKED_ACTIVE_CRITICAL + 1
          else
            counts.GONE_UNACKED_CRITICAL = counts.GONE_UNACKED_CRITICAL + 1
          end
        end
      end
    end
    self.counts_cache = counts
  end
  return self.counts_cache
end

function alerts:render_summary()
  if not self.summary_cache then
    local counts = self:get_counts_by_severity()
    self.summary_cache = string.format("STOERUNG:%d WARNUNG:%d ZU QUITT.:%d",
      counts.CRITICAL or 0, counts.WARN or 0, counts.UNACKED or 0)
  end
  return self.summary_cache
end

return alerts
