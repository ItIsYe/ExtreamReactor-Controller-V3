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

local global = resolve_global()
global.turbine_ctrl = type(global.turbine_ctrl) == "table" and global.turbine_ctrl or {}
global.ensure_turbine_ctrl = ensure_turbine_ctrl

return ensure_turbine_ctrl
