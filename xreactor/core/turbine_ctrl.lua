-- turbine_ctrl.lua: Modul-lokaler Store für Turbinen-Ctrl-Objekte.
-- Kein _G/_ENV Zugriff mehr. Store wird über M.reset() geleert.
local M = {}

local store = {}

local function ensure(name)
  if not name then name = "__unknown__" end
  local ctrl = store[name]
  if type(ctrl) ~= "table" then
    ctrl = {}
    store[name] = ctrl
  end
  if ctrl.mode == nil then ctrl.mode = "INIT" end
  if ctrl.flow == nil then ctrl.flow = 0 end
  if ctrl.requested_flow == nil then ctrl.requested_flow = ctrl.flow end
  if ctrl.confirmed_flow == nil then ctrl.confirmed_flow = ctrl.flow end
  if ctrl.target_flow == nil then ctrl.target_flow = 0 end
  if ctrl.pending_flow_since == nil then ctrl.pending_flow_since = 0 end
  if ctrl.pending_expected_flow == nil then ctrl.pending_expected_flow = ctrl.requested_flow end
  if ctrl.pending_retries == nil then ctrl.pending_retries = 0 end
  if ctrl.pending_retry_stage == nil then ctrl.pending_retry_stage = 0 end
  if ctrl.effective_min_flow == nil then ctrl.effective_min_flow = nil end
  if ctrl.effective_min_hits == nil then ctrl.effective_min_hits = 0 end
  if ctrl.effective_max_flow == nil then ctrl.effective_max_flow = nil end
  if ctrl.startup_synced == nil then ctrl.startup_synced = false end
  if ctrl.last_rpm == nil then ctrl.last_rpm = 0 end
  if ctrl.last_update == nil then ctrl.last_update = os.clock() end
  if ctrl.target_holding_active == nil then ctrl.target_holding_active = false end
  if ctrl.target_band_status == nil then ctrl.target_band_status = "TRACKING" end
  if ctrl.in_target_band == nil then ctrl.in_target_band = false end
  if ctrl.target_trim_active == nil then ctrl.target_trim_active = false end
  if ctrl.target_trim_state == nil then ctrl.target_trim_state = "NONE" end
  if ctrl.flow_limit_state == nil then ctrl.flow_limit_state = "NONE" end
  if ctrl.target_hold_hits == nil then ctrl.target_hold_hits = 0 end
  if ctrl.last_active_command == nil then ctrl.last_active_command = nil end
  if ctrl.last_active_command_reason == nil then ctrl.last_active_command_reason = nil end
  if ctrl.last_coil_reason == nil then ctrl.last_coil_reason = nil end
  if ctrl.overspeed_floor_hits == nil then ctrl.overspeed_floor_hits = 0 end
  return ctrl
end

-- reset: leert den kompletten Store (z.B. bei Node-Restart).
-- Optionaler name-Parameter löscht nur einen einzelnen Eintrag.
function M.reset(name)
  if name then
    store[name] = nil
  else
    for k in pairs(store) do store[k] = nil end
  end
end

-- ensure_turbine_ctrl: gibt das Ctrl-Objekt für eine Turbine zurück,
-- legt es bei Bedarf neu an.
setmetatable(M, { __call = function(_, n) return ensure(n) end })

return M
