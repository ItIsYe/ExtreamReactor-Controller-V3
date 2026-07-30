-- xreactor/optional/pocket_query_handler.lua
--
-- Optionale Peripherie: Pocket-Computer Fernabfrage.
--
-- Zweck: ein Pocket Computer (oder jeder andere Computer mit Ender Modem,
-- der sich nicht als regulaerer Node registriert) sendet auf Kanal 6501
-- eine POCKET_QUERY-Nachricht und bekommt vom Master eine einmalige
-- POCKET_STATUS-Antwort mit einer kompakten Text-Zusammenfassung zurueck.
-- Kein Dauerabo, keine Registrierung im Node-Registry — jede Abfrage ist
-- unabhaengig, der Master merkt sich nichts ueber den fragenden Pocket
-- Computer.
--
-- Läuft NUR am Master. Wird von master/message_handlers.lua aufgerufen,
-- sofern die Datei installiert ist (siehe dortigen pcall(require, ...)).
-- Design-Prinzip wie bei allen optional/-Modulen: vollstaendig
-- fehlerisoliert, kann den normalen Message-Dispatch nicht beeinflussen.

local M = {}

-- build_summary(runtime_snapshot): runtime_snapshot ist eine einfache
-- Tabelle mit den Werten, die der Aufrufer (message_handlers.lua) bereits
-- kennt — dieses Modul rechnet nichts selbst nach, es formatiert nur.
-- Erwartete Felder (alle optional, fehlende werden als "-" angezeigt):
--   power_target, power_actual, energy_percent, active_profile,
--   rt_active, rt_total, critical_count, warn_count
local function build_summary(s)
  s = s or {}
  local function num(v, fmt)
    local n = tonumber(v)
    if not n then return "-" end
    return string.format(fmt or "%.0f", n)
  end
  local lines = {
    string.format("Soll %s / Ist %s MRF/t", num(s.power_target, "%.1f"), num(s.power_actual, "%.1f")),
    string.format("Energie %s%% | Profil %s", num(s.energy_percent), tostring(s.active_profile or "-")),
    string.format("RT %s/%s aktiv", num(s.rt_active), num(s.rt_total)),
    string.format("Alarme C:%s W:%s", num(s.critical_count), num(s.warn_count)),
  }
  return table.concat(lines, " | ")
end

-- handle(message, ctx): ctx braucht mindestens { comms = <comms Modul>,
-- constants = <constants module>, log = <log function>, build_snapshot =
-- <function returning the summary fields above>, sender_id = <string, die
-- eigene ID des Nachrichtenempfaengers, z.B. "POCKET">. Gibt true zurueck
-- wenn die Nachricht behandelt wurde (also message.type == POCKET_QUERY
-- war), sonst false — der Aufrufer kann dann mit seinem eigenen Dispatch
-- fortfahren.
function M.handle(message, ctx)
  if not message or not ctx then return false end
  if message.type == (ctx.constants and ctx.constants.message_types and ctx.constants.message_types.POCKET_QUERY) then
    pcall(function()
      local snapshot = (type(ctx.build_snapshot) == "function") and ctx.build_snapshot() or {}
      local summary_text = build_summary(snapshot)
      if ctx.comms and type(ctx.comms.send) == "function" then
        -- Antwort explizit auf dem Status-Kanal senden (nicht dem Control-
        -- Kanal-Default von comms.send fuer unbekannte Nachrichtentypen) —
        -- Pocket Computer lauschen typischerweise dort, wo auch normale
        -- STATUS-Nachrichten laufen.
        local channel = (ctx.constants and ctx.constants.channels and ctx.constants.channels.STATUS) or nil
        ctx.comms.send(message.sender_id, ctx.constants.message_types.POCKET_STATUS,
          { summary = summary_text, ts = os.epoch and os.epoch("utc") or 0 },
          channel and { channel = channel } or nil)
      end
      if ctx.log then
        ctx.log(("Pocket query answered for sender=%s"):format(tostring(message.sender_id)), "INFO")
      end
    end)
    return true
  end

  -- Feature (2026-07-02): POCKET_COMMAND — Fernsteuerung mit
  -- Token-Absicherung. ctx.current_token muss vom Aufrufer bereitgestellt
  -- werden (rotierendes Token, am Master-Overview sichtbar). Nur exakt
  -- passendes Token wird ausgefuehrt, sonst REJECTED-Antwort ohne
  -- Seiteneffekt. ctx.execute_command(action, params) fuehrt die
  -- eigentliche Aktion aus (vom Aufrufer bereitgestellt, damit dieses
  -- Modul selbst keine Kenntnis von rt_sync/alert_service etc. braucht).
  if message.type == (ctx.constants and ctx.constants.message_types and ctx.constants.message_types.POCKET_COMMAND) then
    pcall(function()
      local payload = message.payload or {}
      local channel = (ctx.constants and ctx.constants.channels and ctx.constants.channels.STATUS) or nil
      local send_opts = channel and { channel = channel } or nil
      local result_type = ctx.constants.message_types.POCKET_COMMAND_RESULT

      local provided_token = tostring(payload.token or "")
      local expected_token = tostring(ctx.current_token or "")
      if expected_token == "" or provided_token ~= expected_token then
        if ctx.comms and type(ctx.comms.send) == "function" then
          ctx.comms.send(message.sender_id, result_type,
            { ok = false, reason = "Token ungueltig oder abgelaufen — aktuelles Token am Master-Overview ablesen" }, send_opts)
        end
        if ctx.log then
          ctx.log(("Pocket command REJECTED (bad token) sender=%s action=%s"):format(
            tostring(message.sender_id), tostring(payload.action)), "WARN")
        end
        return
      end

      local ok_exec, exec_result = false, "Keine execute_command-Funktion bereitgestellt"
      if type(ctx.execute_command) == "function" then
        ok_exec, exec_result = pcall(ctx.execute_command, payload.action, payload.params)
        if not ok_exec then exec_result = tostring(exec_result) end
      end

      if ctx.comms and type(ctx.comms.send) == "function" then
        ctx.comms.send(message.sender_id, result_type,
          { ok = ok_exec == true or ok_exec == nil, reason = tostring(exec_result or "OK") }, send_opts)
      end
      if ctx.log then
        ctx.log(("Pocket command action=%s ok=%s sender=%s"):format(
          tostring(payload.action), tostring(ok_exec), tostring(message.sender_id)), "INFO")
      end
    end)
    return true
  end

  return false
end

return M
