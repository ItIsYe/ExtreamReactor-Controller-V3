local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if type(config_values.loop_tanks) ~= "table" then
    config_values.loop_tanks = utils.deep_copy(defaults.loop_tanks)
    add_warning("loop_tanks missing/invalid; defaulting to configured list")
  end
  if type(config_values.target_volume) ~= "number" or config_values.target_volume < 0 then
    config_values.target_volume = defaults.target_volume
    add_warning("target_volume missing/invalid; defaulting to " .. tostring(defaults.target_volume))
  end
  if type(config_values.balance_log_interval_s) ~= "number" or config_values.balance_log_interval_s < 0 then
    config_values.balance_log_interval_s = defaults.balance_log_interval_s
    add_warning("balance_log_interval_s missing/invalid; defaulting to " .. tostring(defaults.balance_log_interval_s))
  end
end

return M
