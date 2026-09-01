-- master/loop.lua
-- Event-Loop des Masters. Sauber getrennt von Bootstrap/Init.

local M = {}

local update_handshake = require("core.update_handshake")

local REDSTONE_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local function make_redstone_handler(runtime, log)
  local remote_update = require("core.remote_update")
  local last = {}
  for _, s in ipairs(REDSTONE_SIDES) do last[s] = false end
  return function()
    if not redstone or type(redstone.getInput) ~= "function" then return end
    for _, side in ipairs(REDSTONE_SIDES) do
      local ok, current = pcall(redstone.getInput, side)
      if ok and current and not last[side] then
        local update_command, command_err = remote_update.build_command()
        if not update_command then
          log("Remote-Update blockiert: " .. tostring(command_err), "ERROR")
          for _, s2 in ipairs(REDSTONE_SIDES) do last[s2] = true end
          return
        end
        log("Redstone-Trigger: broadcasting REMOTE_UPDATE", "WARN")
        local nodes = runtime.state.nodes or {}
        local count = 0; for _ in pairs(nodes) do count = count + 1 end
        if count == 0 then
          log("Remote-Update: KEINE Nodes bekannt", "ERROR")
        end
        local sent = 0
        for node_id in pairs(nodes) do
          local ok2, entry = pcall(runtime.refs.comms.send_command, runtime.refs.comms,
            node_id, update_command)
          if ok2 and entry then sent = sent + 1 end
        end
        log(("Broadcast: sent=%d known=%d"):format(sent, count), "WARN")
        for _ = 1, 10 do runtime.refs.services:tick(); os.sleep(0.05) end
        local queued = remote_update.queue_local({
          log_fn = function(level, text) log(text, level) end,
          trigger = "REDSTONE",
          source = runtime.refs.comms.network and runtime.refs.comms.network.id or "MASTER",
        })
        if queued.ok ~= true then
          log("Master-Update konnte nicht vorgemerkt werden: " .. tostring(queued.error), "ERROR")
        end
        for _, s2 in ipairs(REDSTONE_SIDES) do last[s2] = true end
        return
      end
      if ok then last[side] = current and true or false end
    end
  end
end

function M.run(runtime, constants)
  local log = runtime.log
  local check_redstone = make_redstone_handler(runtime, log)
  -- MASTER hat keine physischen Aktoren zu quiescen (nur Koordination) --
  -- der Handler bestaetigt sofort einen sicheren Zustand und verlaesst
  -- kontrolliert die Schleife, statt waehrend eines Auto-Updates
  -- unbegrenzt weiterzulaufen.
  local quiesce_handshake = _G.__xreactor_update_handshake
  log("Entering event loop", "INFO")
  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      local ev = event[1]
      if ev == "modem_message" then
        runtime.refs.comms:handle_event(event)
      elseif ev == "monitor_touch" or ev == "mouse_click" or ev == "key" or ev == "char" then
        runtime.refs.services:tick(nil, event)
      elseif ev == "redstone" then
        check_redstone()
      elseif ev == "timer" and event[2] == timer then
        break
      end
    end
    if runtime.refs.services then
      pcall(runtime.refs.services.tick, runtime.refs.services)
    end
    if quiesce_handshake and update_handshake.is_quiesce_requested(quiesce_handshake) then
      update_handshake.mark_safe_outputs_applied(quiesce_handshake)
      update_handshake.mark_runtime_stopped(quiesce_handshake)
      log("Quiesce angefordert -- Event-Loop wird kontrolliert beendet", "WARN")
      return
    end
    -- MASTER-Gesamtampel (Feature, 2026-07-02): siehe
    -- xreactor/optional/master_ampel.lua. Eigenes Rate-Limiting (alle ~3s),
    -- nicht bei jedem 0.5s-Loop-Tick neu rechnen. Vollstaendig
    -- fehlerisoliert wie alle optional/-Module.
    runtime.state.last_master_ampel_check = runtime.state.last_master_ampel_check or 0
    local now_ampel = os.epoch and os.epoch("utc") or 0
    if now_ampel - runtime.state.last_master_ampel_check >= 3000 then
      runtime.state.last_master_ampel_check = now_ampel
      pcall(function()
        local ok_mod, mod = pcall(require, "optional.master_ampel")
        if ok_mod then
          mod.update(runtime, constants)
        end
      end)
    end
  end
end

return M
