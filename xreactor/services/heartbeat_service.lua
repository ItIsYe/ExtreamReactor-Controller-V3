-- services/heartbeat_service.lua
-- Wiederverwendbarer Heartbeat-Service für alle Nodes.
-- Sendet periodisch Heartbeats via comms, misst Verzögerungen.
-- Konfigurierbar über opts.interval_ms und opts.build_state.

local M = {}

-- Feature (2026-07-02): manifest_version wird einmalig aus dem lokal
-- installierten /xreactor/release.lua gelesen und automatisch an JEDEN
-- Heartbeat-Payload angehaengt (build_state-Ergebnis wird gemergt, nicht
-- ersetzt). Zentral hier statt in jedem einzelnen Node-Typ dupliziert —
-- ermoeglicht die AUX-Monitor "Updates"-Seite am Master, die Version pro
-- Node anzuzeigen. Wird nur einmal beim Erstellen des Services gelesen
-- (aendert sich sowieso nicht zur Laufzeit, nur nach einem Reinstall/
-- Reboot), nicht bei jedem einzelnen Heartbeat neu von der Disk gelesen.
local function read_local_manifest_version()
  local ok, version = pcall(function()
    if not fs or not fs.exists or not fs.exists("/xreactor/release.lua") then return nil end
    local f = fs.open("/xreactor/release.lua", "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    local chunk = load(raw, "=release", "t", {})
    if not chunk then return nil end
    local data = chunk()
    return type(data) == "table" and data.manifest_version or nil
  end)
  if ok then return version end
  return nil
end

-- Erstellt einen neuen Heartbeat-Service.
-- opts:
--   comms          — comms_service Instanz (required)
--   interval_ms    — Intervall in ms (default 2000)
--   build_state    — function(ts_ms) -> state-Tabelle für Heartbeat
--   log            — function(msg, level) optional
--   on_send        — function(ts_ms) callback nach jedem Heartbeat
function M.new(opts)
  opts = opts or {}
  local comms       = assert(opts.comms, "comms required")
  local interval_ms = tonumber(opts.interval_ms) or 2000
  local build_state = opts.build_state or function() return {} end
  local log         = opts.log or function() end
  local on_send     = opts.on_send
  local manifest_version = read_local_manifest_version()

  local state = {
    last_ts      = 0,
    last_warn_ts = 0,
  }

  -- Prüft ob Heartbeat fällig ist
  local function is_due(now_ms)
    return (now_ms - state.last_ts) >= interval_ms
  end

  -- Sendet Heartbeat wenn fällig
  local function pump(now_ms)
    if not is_due(now_ms) then return false end
    -- Verzögerungs-Warnung
    if state.last_ts > 0 then
      local delayed = now_ms - state.last_ts
      if delayed > interval_ms * 2 then
        if (now_ms - state.last_warn_ts) >= interval_ms * 2 then
          log(("Heartbeat delayed by %dms (interval=%dms)"):format(delayed, interval_ms), "WARN")
          state.last_warn_ts = now_ms
        end
      end
    end
    local hb_state = build_state(now_ms)
    if type(hb_state) == "table" and manifest_version then
      hb_state.manifest_version = manifest_version
    end
    comms:send_heartbeat(hb_state)
    comms:tick(now_ms)
    state.last_ts = now_ms
    if on_send then on_send(now_ms) end
    return true
  end

  -- Führt den Heartbeat-Loop aus (blockiert, für parallel.waitForAny).
  -- event_filter: function(ev, ...) -> bool — welche Events auch den Heartbeat triggern
  local function run(event_filter)
    while true do
      local timer = os.startTimer(interval_ms / 1000)
      while true do
        local event = { os.pullEventRaw() }
        local ev = event[1]
        if ev == "terminate" then return "terminate" end
        if ev == "timer" and event[2] == timer then
          pump(os.epoch("utc"))
          break
        end
        -- Optionaler Event-Filter: z.B. modem_message triggert auch Pump
        if event_filter and event_filter(ev) then
          pump(os.epoch("utc"))
        end
      end
    end
  end

  return {
    pump     = pump,
    run      = run,
    is_due   = is_due,
    interval = interval_ms,
    state    = state,
  }
end

return M
