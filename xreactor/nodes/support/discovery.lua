local M = {}

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

return M
