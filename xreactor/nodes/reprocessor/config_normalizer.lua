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
  if type(lg.max_per_cycle) ~= "number" or lg.max_per_cycle <= 0 then
    lg.max_per_cycle = (defaults.logistics and defaults.logistics.max_per_cycle) or 64
  end
  if type(lg.sources) ~= "table" then lg.sources = {} end
  if type(lg.destinations) ~= "table" then lg.destinations = {} end
  if type(lg.routes) ~= "table" then lg.routes = {} end
  local valid_tags = { reprocessor_input = true, reprocessor_output = true, me = true, reactor_injector = true, generic = true }
  for i, dest in ipairs(lg.destinations) do
    if type(dest) == "table" and dest.tag and not valid_tags[dest.tag] then
      add_warning(string.format(
        "logistics.destinations[%d].tag '%s' unknown; valid: reactor_injector, reprocessor, fuel_storage, generic",
        i, tostring(dest.tag)
      ))
    end
  end
end

return M
