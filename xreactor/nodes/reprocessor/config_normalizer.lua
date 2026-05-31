local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if type(config_values.buffers) ~= "table" then
    config_values.buffers = utils.deep_copy(defaults.buffers)
    add_warning("buffers missing/invalid; defaulting to configured list")
  end
end

return M
