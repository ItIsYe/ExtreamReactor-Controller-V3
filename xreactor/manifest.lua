return {
  manifest_version = 5,
  source_ref = "beta",
  hash_algo = "crc32",
  base_files = {
    { path = "adapters/energy_storage.lua", size_bytes = 3038, hash = "c1883304" },
    { path = "adapters/induction_matrix.lua", size_bytes = 4655, hash = "95078398" },
    { path = "adapters/monitor.lua", size_bytes = 3202, hash = "f9eaca60" },
    { path = "adapters/reactor.lua", size_bytes = 3894, hash = "bbc5dc89" },
    { path = "adapters/turbine.lua", size_bytes = 3485, hash = "e2d43c15" },
    { path = "core/alert_rules.lua", size_bytes = 12921, hash = "f4c32c65" },
    { path = "core/alerts.lua", size_bytes = 7905, hash = "976d542c" },
    { path = "core/bootstrap.lua", size_bytes = 10439, hash = "8ba4ba0c" },
    { path = "core/comms.lua", size_bytes = 17172, hash = "fc8f6e02" },
    { path = "core/control_rails.lua", size_bytes = 2835, hash = "927b12c0" },
    { path = "core/health.lua", size_bytes = 1918, hash = "48d5bd7f" },
    { path = "core/logger.lua", size_bytes = 4429, hash = "30895567" },
    { path = "core/monitor_manager.lua", size_bytes = 2924, hash = "b41a0f0e" },
    { path = "core/network.lua", size_bytes = 4143, hash = "a13e50b1" },
    { path = "core/protocol.lua", size_bytes = 5955, hash = "fc94cb4d" },
    { path = "core/registry.lua", size_bytes = 9265, hash = "78a50cd8" },
    { path = "core/safety.lua", size_bytes = 771, hash = "73bab9de" },
    { path = "core/state_machine.lua", size_bytes = 842, hash = "4ae6c19c" },
    { path = "core/trends.lua", size_bytes = 1791, hash = "d01a6948" },
    { path = "core/turbine_ctrl.lua", size_bytes = 1266, hash = "a0681bf2" },
    { path = "core/ui.lua", size_bytes = 6038, hash = "1d5c8711" },
    { path = "core/ui_router.lua", size_bytes = 5885, hash = "a0991195" },
    { path = "core/utils.lua", size_bytes = 7801, hash = "a425d6c7" },
    { path = "release.lua", size_bytes = 207, hash = "8994add5" },
    { path = "services/alert_service.lua", size_bytes = 10006, hash = "900e97ea" },
    { path = "services/comms_service.lua", size_bytes = 5603, hash = "4153eebb" },
    { path = "services/control_service.lua", size_bytes = 419, hash = "01a44c98" },
    { path = "services/discovery_service.lua", size_bytes = 2445, hash = "4a26ac38" },
    { path = "services/service_manager.lua", size_bytes = 1265, hash = "d91e40ad" },
    { path = "services/telemetry_service.lua", size_bytes = 1773, hash = "bdbe4b9d" },
    { path = "services/ui_service.lua", size_bytes = 571, hash = "c0addbea" },
    { path = "start.lua", size_bytes = 1541, hash = "f8c99b78" },
    { path = "shared/build_info.lua", size_bytes = 874, hash = "19ff720f" },
    { path = "shared/colors.lua", size_bytes = 332, hash = "445d12af" },
    { path = "shared/constants.lua", size_bytes = 1384, hash = "db560e96" },
    { path = "shared/health_codes.lua", size_bytes = 336, hash = "e1d7e466" },
    { path = "shared/telemetry_schema.lua", size_bytes = 680, hash = "42e7fe19" }
  },
  roles = {
    master = {
      { path = "master/config.lua", size_bytes = 7433, hash = "aa261615" },
      { path = "master/main.lua", size_bytes = 37011, hash = "941f1e4d" },
      { path = "master/profiles.lua", size_bytes = 164, hash = "9068a725" },
      { path = "master/startup_sequencer.lua", size_bytes = 3200, hash = "fd879d22" },
      { path = "master/ui/alarms.lua", size_bytes = 1245, hash = "ab00070b" },
      { path = "master/ui/alerts.lua", size_bytes = 25190, hash = "adafc8e9" },
      { path = "master/ui/energy.lua", size_bytes = 4345, hash = "853d19c8" },
      { path = "master/ui/multiview.lua", size_bytes = 11565, hash = "2bceb16e" },
      { path = "master/ui/overview.lua", size_bytes = 4525, hash = "89e0cb55" },
      { path = "master/ui/resources.lua", size_bytes = 5534, hash = "0447e76b" },
      { path = "master/ui/rt_dashboard.lua", size_bytes = 2824, hash = "6ca4b11e" },
      { path = "master/ui/widgets.lua", size_bytes = 775, hash = "aafe7d4a" }
    },
    rt = {
      { path = "nodes/rt/config.lua", size_bytes = 4290, hash = "c4ac557a" },
      { path = "nodes/rt/main.lua", size_bytes = 94787, hash = "183104d7" }
    },
    energy = {
      { path = "nodes/energy/config.lua", size_bytes = 4614, hash = "7b0f8089" },
      { path = "nodes/energy/main.lua", size_bytes = 48146, hash = "2166cee0" }
    },
    water = {
      { path = "nodes/water/config.lua", size_bytes = 3481, hash = "b816f1e2" },
      { path = "nodes/water/main.lua", size_bytes = 22157, hash = "21a2c6a1" }
    },
    fuel = {
      { path = "nodes/fuel/config.lua", size_bytes = 3392, hash = "5a7c94f9" },
      { path = "nodes/fuel/main.lua", size_bytes = 21944, hash = "68e1d206" }
    },
    reprocessing = {
      { path = "nodes/reprocessor/config.lua", size_bytes = 3188, hash = "d5ee204d" },
      { path = "nodes/reprocessor/main.lua", size_bytes = 21250, hash = "5500ead4" }
    }
  }
}
