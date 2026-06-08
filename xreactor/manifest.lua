return {
  manifest_version = 29,
  manifest_id = "manifest-v29",
  source_ref = "beta",
  hash_algo = "none",
  base_files = {
      { path = "adapters/monitor.lua" },
      { path = "core/bootstrap.lua" },
      { path = "core/comms.lua" },
      { path = "core/health.lua" },
      { path = "core/logger.lua" },
      { path = "core/network.lua" },
      { path = "core/non_rt_config.lua" },
      { path = "core