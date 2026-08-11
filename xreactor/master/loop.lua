-- master/loop.lua
-- Event loop for MASTER.

local M = {}
local update_handshake = require("core.update_handshake")

local REDSTONE_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local REMOTE_UPDATE_CONFIG = "/xreactor/config/remote_update.lua"

local function local_update_token()
  if not (fs and fs.exists and fs.exists(REMOTE_UPDATE_CONFIG)) then return nil end
  local h = fs.open(REMOTE_UPDATE_CONFIG, "r")
  if not h then return nil end
  local src = h.readAll(); h.close()
  local loader = load(src, "=master_remote_update", "t", {})
  if not loader then return nil end
  local ok, cfg = pcall(loader)
  if ok and type(cfg) == "table" then return cfg.token end
  return nil
end

local function make_redstone_handler(runtime, log, constants, quiesce_handshake)
  local last = {}
  for _, s in ipairs(REDSTONE_SIDES) do last[s] = false end
  return function()
    if not redstone or type(redstone.getInput) ~= "function" then return end
    for _, side in ipairs(REDSTONE_SIDES) do
      local ok, current = pcall(redstone.getInput, side)
      if ok and current and not last[side] then
        local token = local_update_token()
        log("Redstone-Trigger: broadcasting managed REMOTE_UPDATE", "WARN")
        local nodes = runtime.state.nodes or {}
        local count = 0; for _ in pairs(nodes) do count = count + 1 end
        if count == 0 then log("Remote-Update: KEINE Nodes bekannt", "ERROR") end
        local sent = 0
        for node_id in pairs(nodes) do
          local ok2 = pcall(function()
            runtime.refs.comms:send_command(node_id, {
              target = constants.command_targets.REMOTE_UPDATE,
              token = token,
            })
          end)
          if ok2 then sent = sent + 1 end
        end
        log(("Broadcast: sent=%d known=%d"):format(sent, count), "WARN")
        for _ = 1, 10 do runtime.refs.services:tick(); os.sleep(0.05) end

        -- MASTER itself must use the exact same managed queue as every node.
        -- No installer is allowed to start inside the redstone event handler.
        local result = require("core.remote_update").queue_command({
          token = token,
          trigger = "LOCAL_REDSTONE",
          log_prefix = "MASTER",
          utils = runtime.libs and runtime.libs.utils,
        })
        if result and result.ok then
          log("Master-Update sicher gequeued; Quiesce erfolgt ueber Auto-Updater", "WARN")
        else
          log("Master-Update nicht gequeued: " .. tostring(result and result.error or "unknown"), "ERROR")
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
  local quiesce_handshake = _G.__xreactor_update_handshake
  local check_redstone = make_redstone_handler(runtime, log, constants, quiesce_handshake)
  log("Entering event loop", "INFO")
  while true do
    local timer = os.startTimer(0.5)
    while true do
      local event = { os.pullEvent() }
      local ev = event[1]
      if ev == "modem_message" then
        runtime.refs.comms:handle_event(event)
      elseif ev == "monitor_touch" or ev == "mouse_click" or ev == "key" or ev == "char"
          or ev == "monitor_resize" or ev == "term_resize" then
        runtime.refs.services:tick(nil, event)
      elseif ev == "redstone" then
        check_redstone()
      elseif ev == "timer" and event[2] == timer then
        break
      end
    end
    if runtime.refs.services then pcall(runtime.refs.services.tick, runtime.refs.services) end
    if quiesce_handshake and update_handshake.is_quiesce_requested(quiesce_handshake) then
      update_handshake.mark_safe_outputs_applied(quiesce_handshake)
      update_handshake.mark_runtime_stopped(quiesce_handshake)
      log("Quiesce angefordert -- Event-Loop wird kontrolliert beendet", "WARN")
      return
    end

    runtime.state.last_master_ampel_check = runtime.state.last_master_ampel_check or 0
    local now_ampel = os.epoch and os.epoch("utc") or 0
    if now_ampel - runtime.state.last_master_ampel_check >= 3000 then
      runtime.state.last_master_ampel_check = now_ampel
      pcall(function()
        local ok_mod, mod = pcall(require, "optional.master_ampel")
        if ok_mod then mod.update(runtime, constants) end
      end)
    end
  end
end

return M
