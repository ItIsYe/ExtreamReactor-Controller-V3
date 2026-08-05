-- xreactor/trace/recorder.lua  Phase 8.1
-- Instrumentiert Peripheral-Calls, Events, Modem-Nachrichten, Statuswechsel.
-- Läuft im echten CC:Tweaked; speichert Trace als versionierte Lua-Tabelle.

local M = {}
M.FORMAT_VERSION = 1
M.MAX_ENTRIES    = 50000  -- Größenbeschränkung

function M.new(opts)
  opts = opts or {}
  local rec = {
    _version  = M.FORMAT_VERSION,
    _seed     = opts.seed or 0,
    _node_id  = opts.node_id or "UNKNOWN",
    _role     = opts.role or "UNKNOWN",
    _entries  = {},
    _tick     = 0,
    _enabled  = true,
    _dropped  = 0,
  }

  local function entry(kind, data)
    if not rec._enabled then return end
    if #rec._entries >= M.MAX_ENTRIES then
      rec._dropped = rec._dropped + 1
      return
    end
    rec._entries[#rec._entries + 1] = {
      t    = rec._tick,
      kind = kind,
      data = data,
    }
  end

  -- tick() muss pro Simulations-Schritt aufgerufen werden
  function rec:tick()
    self._tick = self._tick + 1
  end

  -- Peripheral-Call aufzeichnen
  function rec:record_peripheral(name, method, args, result)
    entry("peripheral_call", {
      name   = name,
      method = method,
      args   = args,
      result = result,
    })
  end

  -- Peripheral wrap() instrumentieren
  function rec:wrap_peripheral(name, proxy)
    if not proxy then return nil end
    local wrapped = {}
    for mname, fn in pairs(proxy) do
      if type(fn) == "function" then
        wrapped[mname] = function(...)
          local args = {...}
          local results = {fn(...)}
          self:record_peripheral(name, mname, args, results)
          return table.unpack(results)
        end
      else
        wrapped[mname] = fn
      end
    end
    return wrapped
  end

  -- Event aufzeichnen
  function rec:record_event(event_name, ...)
    entry("event", { name = event_name, args = {...} })
  end

  -- Modem-Nachricht aufzeichnen
  function rec:record_modem_rx(channel, reply_channel, message, distance)
    entry("modem_rx", {
      channel       = channel,
      reply_channel = reply_channel,
      message       = message,
      distance      = distance,
    })
  end

  function rec:record_modem_tx(channel, reply_channel, message)
    entry("modem_tx", {
      channel       = channel,
      reply_channel = reply_channel,
      message       = message,
    })
  end

  -- Statuswechsel aufzeichnen
  function rec:record_state(from_state, to_state, reason)
    entry("state_change", {
      from   = from_state,
      to     = to_state,
      reason = reason,
    })
  end

  -- Entscheidung aufzeichnen (für Replay-Vergleich)
  function rec:record_decision(kind, value, context)
    entry("decision", {
      kind    = kind,
      value   = value,
      context = context,
    })
  end

  -- Trace als Lua-String serialisieren
  function rec:serialize()
    local lines = {
      "-- XReactor Trace v" .. self._version,
      "-- node_id: " .. tostring(self._node_id),
      "-- role:    " .. tostring(self._role),
      "-- ticks:   " .. tostring(self._tick),
      "-- entries: " .. tostring(#self._entries),
      "-- dropped: " .. tostring(self._dropped),
      "return {",
      "  format_version = " .. self._version .. ",",
      "  node_id = " .. string.format("%q", self._node_id) .. ",",
      "  role    = " .. string.format("%q", self._role) .. ",",
      "  seed    = " .. tostring(self._seed) .. ",",
      "  ticks   = " .. tostring(self._tick) .. ",",
      "  dropped = " .. tostring(self._dropped) .. ",",
      "  entries = {",
    }
    for _, e in ipairs(self._entries) do
      local data_s = "{"
      if type(e.data) == "table" then
        for k, v in pairs(e.data) do
          local vs
          if type(v) == "string" then vs = string.format("%q", v)
          elseif type(v) == "number" then vs = tostring(v)
          elseif type(v) == "boolean" then vs = tostring(v)
          elseif type(v) == "table" then vs = "{}"  -- Shallow; deep copy via real impl
          else vs = string.format("%q", tostring(v)) end
          data_s = data_s .. string.format("[%q]=%s,", tostring(k), vs)
        end
      end
      data_s = data_s .. "}"
      lines[#lines+1] = string.format(
        "    {t=%d,kind=%q,data=%s},", e.t, e.kind, data_s)
    end
    lines[#lines+1] = "  },"
    lines[#lines+1] = "}"
    return table.concat(lines, "\n")
  end

  -- Trace in Datei schreiben (CC:Tweaked fs)
  function rec:save(fs, path)
    local s = self:serialize()
    local f = fs.open(path, "w")
    if not f then return false, "cannot open " .. path end
    f.write(s); f.close()
    return true
  end

  function rec:stats()
    return {
      ticks   = self._tick,
      entries = #self._entries,
      dropped = self._dropped,
    }
  end

  function rec:entries() return self._entries end
  function rec:enable()  self._enabled = true  end
  function rec:disable() self._enabled = false end

  return rec
end

return M
