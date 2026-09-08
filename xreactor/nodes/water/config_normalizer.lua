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

  -- config.clusters wurde bisher ungeprueft durchgereicht -- ein nicht-
  -- tabellarischer Wert liess main.lua's ipairs(config.clusters or {})
  -- crashen (nur nil/false fielen auf {} zurueck), und ein Cluster ohne
  -- gueltigen Tanknamen oder mit min_volume > max_volume fuehrte zu
  -- Fill/Drain-Logik, die nie sauber ausloest bzw. dauerhaft blockiert.
  -- Genau wie loop_tanks/target_volume oben wird das jetzt zentral
  -- validiert statt main.lua ungepruefte Werte verarbeiten zu lassen.
  if config_values.clusters ~= nil and type(config_values.clusters) ~= "table" then
    add_warning("clusters missing/invalid (not a table); disabling water clusters")
    config_values.clusters = utils.deep_copy(defaults.clusters or {})
  end
  if type(config_values.clusters) == "table" then
    local cleaned = {}
    for i, cluster in ipairs(config_values.clusters) do
      local label = (type(cluster) == "table" and cluster.name) or tostring(i)
      if type(cluster) ~= "table" then
        add_warning("clusters[" .. label .. "] is not a table; skipping entry")
      elseif type(cluster.tank) ~= "string" or cluster.tank == "" then
        add_warning("clusters[" .. label .. "] missing a valid tank name; skipping entry")
      elseif cluster.min_volume ~= nil and cluster.max_volume ~= nil
        and tonumber(cluster.min_volume) and tonumber(cluster.max_volume)
        and tonumber(cluster.min_volume) > tonumber(cluster.max_volume) then
        add_warning("clusters[" .. label .. "] min_volume > max_volume; skipping entry")
      else
        table.insert(cleaned, cluster)
      end
    end
    config_values.clusters = cleaned
  end
end

return M
