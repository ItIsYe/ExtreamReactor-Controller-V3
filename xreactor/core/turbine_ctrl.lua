local function resolve_global()
  local global = _G
  if type(global) ~= "table" then
    global = _ENV
  end
  if type(global) ~= "table" then
    global = {}
  end
  if _G ~= global then
    _G = global
  end
  if type(_ENV) == "table" then
    _ENV._G = global
  end
  return global
end

local function ensure_turbine_ctrl(name)
  local global = resolve_global()
  if type(global.turbine_ctrl) ~= "table" then
    global.turbine_ctrl = {}
  end
  if type(global.ensure_turbine_ctrl) ~= "function" then
    global.ensure_turbine_ctrl = ensure_turbine_ctrl
  end
  if not name then
    name = "__unknown__"
  end
  local ctrl = global.turbine_ctrl[name]
  if type(ctrl) ~= "table" then
    ctrl = {}
    global.turbine_ctrl[name] = ctrl
  end
  if ctrl.mode == nil then
    ctrl.mode = "INIT"
  end
  if ctrl.flow == nil then
    ctrl.flow = 0
  end
  if ctrl.requested_flow == nil then
    ctrl.requested_flow = ctrl.flow
  end
  if ctrl.confirmed_flow == nil then
    ctrl.confirmed_flow = ctrl.flow
  end
  if ctrl.target_flow == nil then
    ctrl.target_flow = 0
  end
  if ctrl.pending_flow_since == nil then
    ctrl.pending_flow_since = 0
  end
  if ctrl.pending_expected_flow == nil then
    ctrl.pending_expected_flow = ctrl.requested_flow
  end
  if ctrl.pending_retries == nil then
    ctrl.pending_retries = 0
  end
  if ctrl.effective_min_flow == nil then
    ctrl.effective_min_flow = nil
  end
  if ctrl.effective_min_hits == nil then
    ctrl.effective_min_hits = 0
  end
  if ctrl.effective_max_flow == nil then
    ctrl.effective_max_flow = nil
  end
  if ctrl.startup_synced == nil then
    ctrl.startup_synced = false
  end
  if ctrl.last_rpm == nil then
    ctrl.last_rpm = 0
  end
  if ctrl.last_update == nil then
    ctrl.last_update = os.clock()
  end
  if ctrl.target_holding_active == nil then
    ctrl.target_holding_active = false
  end
  if ctrl.target_band_status == nil then
    ctrl.target_band_status = "TRACKING"
  end
  if ctrl.in_target_band == nil then
    ctrl.in_target_band = false
  end
  if ctrl.target_trim_active == nil then
    ctrl.target_trim_active = false
  end
  if ctrl.target_trim_state == nil then
    ctrl.target_trim_state = "NONE"
  end
  if ctrl.flow_limit_state == nil then
    ctrl.flow_limit_state = "NONE"
  end
  if ctrl.target_hold_hits == nil then
    ctrl.target_hold_hits = 0
  end
  if ctrl.last_active_command == nil then
    ctrl.last_active_command = nil
  end
  if ctrl.last_active_command_reason == nil then
    ctrl.last_active_command_reason = nil
  end
  if ctrl.last_coil_reason == nil then
    ctrl.last_coil_reason = nil
  end
  if ctrl.overspeed_floor_hits == nil then
    ctrl.overspeed_floor_hits = 0
  end
  return ctrl
end

local global = resolve_global()
global.turbine_ctrl = type(global.turbine_ctrl) == "table" and global.turbine_ctrl or {}
global.ensure_turbine_ctrl = ensure_turbine_ctrl

return ensure_turbine_ctrl
