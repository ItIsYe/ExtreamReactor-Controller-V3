local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if type(config_values.buffers) ~= "table" then
    config_values.buffers = utils.deep_copy(defaults.buffers)
    add_warning("buffers missing/invalid; defaulting to configured list")
  end

  -- Normalize feed config block (random-interval Cyanite supply to reprocessors).
  if config_values.feed == nil then
    config_values.feed = utils.deep_copy(defaults.feed) or {}
  end
  local fd = config_values.feed
  if type(fd) ~= "table" then
    fd = {}
    config_values.feed = fd
    add_warning("feed config invalid; using defaults")
  end
  local d = defaults.feed or {}
  if fd.enabled ~= true then fd.enabled = false end
  if type(fd.me_bridge) ~= "string" then
    fd.me_bridge = d.me_bridge or "me_bridge"
  end
  if type(fd.waste_item) ~= "string" then
    fd.waste_item = d.waste_item or "bigreactors:cyanite_ingot"
  end
  if type(fd.feed_amount) ~= "number" or fd.feed_amount <= 0 then
    fd.feed_amount = d.feed_amount or 2
  end
  if type(fd.interval_min_s) ~= "number" or fd.interval_min_s <= 0 then
    fd.interval_min_s = d.interval_min_s or 20
  end
  if type(fd.interval_max_s) ~= "number" or fd.interval_max_s < fd.interval_min_s then
    fd.interval_max_s = math.max(d.interval_max_s or 60, fd.interval_min_s)
  end
  if type(fd.valve_open_ms) ~= "number" or fd.valve_open_ms <= 0 then
    fd.valve_open_ms = d.valve_open_ms or 2000
  end
  if type(fd.discovery_interval) ~= "number" or fd.discovery_interval <= 0 then
    fd.discovery_interval = d.discovery_interval or 60
  end
  if type(fd.targets) ~= "table" then fd.targets = {} end
  if type(fd.redstone_tree) ~= "table" then fd.redstone_tree = {} end
  for i, t in ipairs(fd.targets) do
    if not t.inlet then
      add_warning(string.format("feed.targets[%d] missing inlet", i))
    end
    if not t.label then
      add_warning(string.format("feed.targets[%d] missing label", i))
    end
  end
end

return M
