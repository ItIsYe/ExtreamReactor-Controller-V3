local utils = require("core.utils")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")

local manager = {}

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(function(...)
    return obj[method](...)
  end, ...)
end

local function classify_size(w, h, thresholds)
  local area = (w or 0) * (h or 0)
  local small = thresholds and thresholds.small_area or 600
  local medium = thresholds and thresholds.medium_area or 1100
  if area <= small then
    return "small"
  end
  if area <= medium then
    return "medium"
  end
  return "large"
end

local function classify_layout(width, height, size_tag)
  local area = (width or 0) * (height or 0)
  if size_tag == "large" or (area >= 900 and (width or 0) >= 48 and (height or 0) >= 18) then
    return "master_large"
  end
  if size_tag == "medium" then
    return "master_medium"
  end
  return "compact"
end

local function build_devices(names)
  local devices = {}
  for _, name in ipairs(names or {}) do
    local methods = utils.safe_get_methods(name) or {}
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

local function prune_wrap_cache(self, present_names)
  for name, _ in pairs(self.wrap_cache or {}) do
    if not present_names[name] then
      self.wrap_cache[name] = nil
    end
  end
end

function manager:new_wrapped_monitor(name)
  local mon = utils.safe_wrap(name)
  if mon then
    self.wrap_cache[name] = mon
  else
    self.wrap_cache[name] = nil
  end
  return mon
end

function manager:get_wrapped_monitor(name)
  local mon = self.wrap_cache[name]
  if mon and type(mon.getSize) == "function" then
    return mon
  end
  return self:new_wrapped_monitor(name)
end

function manager.new(opts)
  opts = opts or {}
  local scale = tonumber(opts.scale)
  local self = {
    log_prefix = opts.log_prefix or "MONITOR",
    scale = scale,
    thresholds = opts.thresholds or { small_area = 600, medium_area = 1100 },
    registry = registry_lib.new({
      role = opts.role or "master_monitor",
      node_id = opts.node_id or "MASTER",
      path = opts.path
    }),
    disabled = {},
    scale_cache = {},
    wrap_cache = {}
  }
  return setmetatable(self, { __index = manager })
end

function manager:scan()
  local names = {}
  local present_names = {}
  for _, name in ipairs(peripheral.getNames() or {}) do
    if peripheral.getType(name) == "monitor" then
      table.insert(names, name)
      present_names[name] = true
    end
  end
  table.sort(names)
  prune_wrap_cache(self, present_names)
  monitor_adapter.sync_names(names)
  if #names == 0 then
    local ok, w, h = pcall(term.getSize)
    local width = ok and w or 0
    local height = ok and h or 0
    local size_tag = classify_size(width, height, self.thresholds)
    return { { id = "TERM", name = "term", mon = term, size_tag = size_tag, width = width, height = height, is_terminal = true } }
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
    local mon = self:get_wrapped_monitor(entry.name)
    if mon then
      if self.scale then
        local cached_scale = self.scale_cache[entry.name]
        local should_apply_scale = cached_scale == nil or tonumber(cached_scale) ~= tonumber(self.scale)
        if should_apply_scale then
          local scale_ok, scale_err = monitor_adapter.safe_set_scale(mon, entry.name, self.scale, self.log_prefix)
          if not scale_ok then
            self.disabled[entry.name] = "setTextScale failed: " .. tostring(scale_err)
            utils.log(self.log_prefix, "Disabling monitor " .. tostring(entry.name) .. " during scan (setTextScale failed: " .. tostring(scale_err) .. ")", "WARN")
            self.wrap_cache[entry.name] = nil
            goto continue
          end
          self.scale_cache[entry.name] = self.scale
          utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " text scale applied=" .. tostring(self.scale), "DEBUG")
        else
          utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " text scale unchanged=" .. tostring(self.scale), "DEBUG")
        end
      end
      local effective_scale = self.scale
      local scale_read_ok, scale_read = safe_wrapped_call(mon, "getTextScale")
      if scale_read_ok then
        effective_scale = tonumber(scale_read) or effective_scale
      end
      local ok, w, h = safe_wrapped_call(mon, "getSize")
      if not ok then
        self.wrap_cache[entry.name] = nil
        mon = self:new_wrapped_monitor(entry.name)
        ok, w, h = safe_wrapped_call(mon, "getSize")
      end
      if not ok then
        self.disabled[entry.name] = "getSize failed: " .. tostring(w)
        utils.log(self.log_prefix, "Disabling monitor " .. tostring(entry.name) .. " during scan (getSize failed: " .. tostring(w) .. ")", "WARN")
        goto continue
      end
      local width = ok and w or 0
      local height = ok and h or 0
      local size_tag = classify_size(width, height, self.thresholds)
      if self.disabled[entry.name] then
        self.disabled[entry.name] = nil
        utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " recovered and re-enabled", "INFO")
      end
      table.insert(monitors, {
        id = entry.id or entry.name,
        name = entry.name,
        mon = mon,
        width = width,
        height = height,
        size_tag = size_tag,
        text_scale = effective_scale,
        layout_class = classify_layout(width, height, size_tag),
        last_applied_scale = self.scale_cache[entry.name]
      })
    else
      utils.log(self.log_prefix, "Monitor wrap failed for " .. tostring(entry.name), "WARN")
      self.disabled[entry.name] = "wrap failed"
      self.wrap_cache[entry.name] = nil
    end
    ::continue::
  end
  return monitors
end

return manager
