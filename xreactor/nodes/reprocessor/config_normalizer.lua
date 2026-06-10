local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if type(config_values.buffers) ~= "table" then
    config_values.buffers = utils.deep_copy(defaults.buffers)
    add_warning("buffers missing/invalid; defaulting to configured list")
  end

  -- Normalize logistics config block (output routing from reprocessor).
  if config_values.logistics == nil then
    config_values.logistics = { enabled = false, interval = 10, discovery_interval = 60,
                                 max_per_cycle = 64, sources = {}, destinations = {}, routes = {} }
  end
  local lg = config_values.logistics
  if type(lg) ~= "table" then
    lg = {}
    config_values.logistics = lg
    add_warning("logistics config invalid; using defaults")
  end
  if lg.enabled ~= true then lg.enabled = false end
  if type(lg.interval) ~= "number" or lg.interval <= 0 then
    lg.interval = (defaults.logistics and defaults.logistics.interval) or 10
  end
  if type(lg.discovery_interval) ~= "number" or lg.discovery_interval <= 0 then
    lg.discovery_interval = (defaults.logistics and defaults.logistics.discovery_interval) or 60
  end
  if type(lg.reprocessors) ~= "table" then lg.reprocessors = {} end
  if type(lg.me_bridge)    ~= "string" then
    lg.me_bridge = (defaults.logistics and defaults.logistics.me_bridge) or "me_bridge"
  end
  for i, r in ipairs(lg.reprocessors) do
    if not r.inlet then
      add_warning(string.format("logistics.reprocessors[%d] missing inlet", i))
    end
    if not r.waste_item then
      add_warning(string.format("logistics.reprocessors[%d] missing waste_item", i))
    end
  end
end

return M
