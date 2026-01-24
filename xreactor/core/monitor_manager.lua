local utils = require("core.utils")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")

local manager = {}

local function classify_size(w, h, thresholds)
  local area = (w or 0) * (h or 0)
  local small = thresholds and thresholds.small_area or 300
  local medium = thresholds and thresholds.medium_area or 700
  if area <= small then
    return "small"
  end
  if area <= medium then
    return "medium"
  end
  return "large"
end

local function build_devices(names)
  local devices = {}
  for _, name in ipairs(names or {}) do
    local methods = peripheral.getMethods(name) or {}
    table.insert(devices, {
      name = name,
      type = "monitor",
      kind = "monitor",
      methods = methods,
      bound = true,
      found = true
    })
  end
  return devices
end

function manager.new(opts)
  opts = opts or {}
  local self = {
    log_prefix = opts.log_prefix or "MONITOR",
    scale = opts.scale,
    thresholds = opts.thresholds or { small_area = 300, medium_area = 700 },
    registry = registry_lib.new({
      role = opts.role or "master_monitor",
      node_id = opts.node_id or "MASTER",
      path = opts.path
    })
  }
  return setmetatable(self, { __index = manager })
end

function manager:scan()
  local names = {}
  for _, name in ipairs(peripheral.getNames() or {}) do
    if peripheral.getType(name) == "monitor" then
      table.insert(names, name)
    end
  end
  table.sort(names)
  if #names == 0 then
    return { { id = "TERM", name = "term", mon = term, size_tag = "small", width = 0, height = 0, is_terminal = true } }
  end
  self.registry:sync(build_devices(names))
  local order = self.registry:get_order_index()
  local entries = {}
  for _, entry in ipairs(self.registry:list("monitor")) do
    if entry and entry.name and peripheral.isPresent(entry.name) then
      table.insert(entries, entry)
    end
  end
  table.sort(entries, function(a, b)
    local rank_a = order[a.id] or math.huge
    local rank_b = order[b.id] or math.huge
    if rank_a ~= rank_b then
      return rank_a < rank_b
    end
    return tostring(a.name) < tostring(b.name)
  end)
  local monitors = {}
  for _, entry in ipairs(entries) do
    local mon = utils.safe_wrap(entry.name)
    if mon then
      if self.scale then
        monitor_adapter.safe_set_scale(mon, entry.name, self.scale, self.log_prefix)
      end
      local ok, w, h = pcall(mon.getSize, mon)
      local width = ok and w or 0
      local height = ok and h or 0
      local size_tag = classify_size(width, height, self.thresholds)
      table.insert(monitors, {
        id = entry.id or entry.name,
        name = entry.name,
        mon = mon,
        width = width,
        height = height,
        size_tag = size_tag
      })
    else
      utils.log(self.log_prefix, "Monitor wrap failed for " .. tostring(entry.name), "WARN")
    end
  end
  return monitors
end

return manager
