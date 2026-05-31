local M = {}

local function build_method_set(methods)
  local set = {}
  for _, method in ipairs(methods or {}) do
    set[method] = true
  end
  return set
end

function M.collect_monitor_device(utils, monitor_name)
  local devices = {}
  local names = peripheral.getNames() or {}
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
      devices[#devices + 1] = {
        name = name,
        type = "monitor",
        methods = utils.safe_get_methods(name) or {},
        kind = "monitor",
        bound = monitor_name == name
      }
    end
  end
  return devices, names
end

function M.collect_devices_by_methods(names, opts)
  local devices = {}
  opts = opts or {}
  for _, name in ipairs(names or {}) do
    if opts.allow_name and not opts.allow_name(name) then
      goto continue
    end
    local ok, methods = pcall(peripheral.getMethods, name)
    if not ok or type(methods) ~= "table" then
      goto continue
    end
    local method_set = build_method_set(methods)
    if opts.match and not opts.match(method_set, name, methods) then
      goto continue
    end
    devices[#devices + 1] = {
      name = name,
      type = peripheral.getType(name),
      methods = methods,
      kind = opts.kind,
      bound = opts.bound ~= false
    }
    ::continue::
  end
  return devices
end

return M
