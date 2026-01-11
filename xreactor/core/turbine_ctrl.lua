local function ensure_turbine_ctrl(name)
  _G = _G or {}
  if type(_G.turbine_ctrl) ~= "table" then
    _G.turbine_ctrl = {}
  end
  if type(_G.ensure_turbine_ctrl) ~= "function" then
    _G.ensure_turbine_ctrl = ensure_turbine_ctrl
  end
  if not name then
    name = "__unknown__"
  end
  local ctrl = _G.turbine_ctrl[name]
  if type(ctrl) ~= "table" then
    ctrl = {}
    _G.turbine_ctrl[name] = ctrl
  end
  if ctrl.mode == nil then
    ctrl.mode = "INIT"
  end
  if ctrl.flow == nil then
    ctrl.flow = 0
  end
  if ctrl.target_flow == nil then
    ctrl.target_flow = 0
  end
  if ctrl.last_rpm == nil then
    ctrl.last_rpm = 0
  end
  if ctrl.last_update == nil then
    ctrl.last_update = os.clock()
  end
  return ctrl
end

_G = _G or {}
_G.turbine_ctrl = type(_G.turbine_ctrl) == "table" and _G.turbine_ctrl or {}
_G.ensure_turbine_ctrl = ensure_turbine_ctrl

return ensure_turbine_ctrl
