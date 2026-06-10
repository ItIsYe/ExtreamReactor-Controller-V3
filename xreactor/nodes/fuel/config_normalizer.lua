local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if config_values.storage_bus ~= nil and type(config_values.storage_bus) ~= "string" then
    config_values.storage_bus = defaults.storage_bus
    add_warning("storage_bus invalid; defaulting to " .. tostring(defaults.storage_bus))
  end
  if config_values.minimum_reserve == nil and type(config_values.target) == "number" then
    config_values.minimum_reserve = config_values.target
    add_warning("minimum_reserve missing; using target value " .. tostring(config_values.target))
  end
  if type(config_values.minimum_reserve) ~= "number" or config_values.minimum_reserve < 0 then
    config_values.minimum_reserve = defaults.minimum_reserve
    add_warning("minimum_reserve missing/invalid; defaulting to " .. tostring(defaults.minimum_reserve))
  end
  if type(config_values.target) ~= "number" or config_values.target < 0 then
    config_values.target = defaults.target
    add_warning("target missing/invalid; defaulting to " .. tostring(defaults.target))
  end

  -- Normalize logistics config block.
  if config_values.logistics == nil then
    config_values.logistics = utils.deep_copy and utils.deep_copy(defaults.logistics)
      or { enabled = false, interval = 10, discovery_interval = 60,
           max_per_cycle = 64, sources = {}, destinations = {}, routes = {} }
  end
  local lg = config_values.logistics
  if type(lg) ~= "table" then
    lg = {}
    config_values.logistics = lg
    add_warning("logistics config invalid; using defaults")
  end
  -- enabled must be explicit boolean true to activate
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
  -- Validate destination tags
  local valid_tags = { reactor_injector = true, reprocessor = true, generic = true }
  for i, dest in ipairs(lg.destinations) do
    if type(dest) == "table" and dest.tag and not valid_tags[dest.tag] then
      add_warning(string.format(
        "logistics.destinations[%d].tag '%s' unknown; valid: reactor_injector, reprocessor, generic",
        i, tostring(dest.tag)
      ))
    end
  end
end

return M
