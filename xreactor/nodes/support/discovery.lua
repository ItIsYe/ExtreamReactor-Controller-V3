local M = {}

local function build_method_set(methods)
  local set = {}
  for _, method in ipairs(methods or {}) do
    set[method] = true
  end
  return set
end

function M.find_first_by_methods(required_methods, names)
  names = names or (peripheral.getNames and peripheral.getNames()) or {}
  for _, name in ipairs(names) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local method_set = build_method_set(methods)
      local matches = true
      for _, method in ipairs(required_methods or {}) do
        if not method_set[method] then matches = false; break end
      end
      if matches then return name end
    end
  end
  return nil
end

-- Resolve a configured peripheral first. Method-based fallback is allowed
-- only when no explicit name was configured, so wiring mistakes stay visible.
function M.resolve_by_methods(opts)
  opts = opts or {}
  local configured_name = opts.configured_name
  local preferred_name = configured_name or opts.default_name
  local found_name = nil
  if preferred_name and peripheral.isPresent then
    local ok, present = pcall(peripheral.isPresent, preferred_name)
    if ok and present then found_name = preferred_name end
  end
  if not found_name and configured_name == nil then
    found_name = M.find_first_by_methods(opts.required_methods, opts.names)
  end
  if not found_name then return nil, nil, "absent" end
  local ok, wrapped = pcall(peripheral.wrap, found_name)
  if not ok or not wrapped then return found_name, nil, "wrap_failed" end
  return found_name, wrapped, nil
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
