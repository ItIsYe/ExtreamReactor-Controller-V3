return {
  manifest_version = 5,
  source_ref = "beta",
  hash_algo = "crc32",
  base_files = {
    { path = "adapters/energy_storage.lua", size_bytes = 3220, hash = "65c983a9" },
    { path = "adapters/induction_matrix.lua", size_bytes = 4655, hash = "95078398" },
    { path = "adapters/monitor.lua", size_bytes = 3403, hash = "68e40543" },
    { path = "adapters/reactor.lua", size_bytes = 3894, hash = "bbc5dc89" },
    { path = "adapters/turbine.lua", size_bytes = 3485, hash = "e2d43c15" },
    { path = "core/alert_rules.lua", size_bytes = 12921, hash = "f4c32c65" },
    { path = "core/alerts.lua", size_bytes = 7905, hash = "976d542c" },
    { path = "core/bootstrap.lua", size_bytes = 10688, hash = "f69b8d8e" },
    { path = "core/comms.lua", size_bytes = 20223, hash = "903b39da" },
    { path = "core/control_rails.lua", size_bytes = 2835, hash = "927b12c0" },
    { path = "core/fluid.lua", size_bytes = 1063, hash = "e1a5837b" },
    { path = "core/health.lua", size_bytes = 1918, hash = "48d5bd7f" },
    { path = "core/logger.lua", size_bytes = 4399, hash = "23101367" },
    { path = "core/monitor_manager.lua", size_bytes = 3114, hash = "58f26df6" },
    { path = "core/network.lua", size_bytes = 5825, hash = "d6f38322" },
    { path = "core/protocol.lua", size_bytes = 6086, hash = "602e75c9" },
    { path = "core/registry.lua", size_bytes = 12481, hash = "f36ffed9" },
    { path = "core/safety.lua", size_bytes = 771, hash = "73bab9de" },
    { path = "core/state_machine.lua", size_bytes = 842, hash = "4ae6c19c" },
    { path = "core/time.lua", size_bytes = 454, hash = "52e5eb5d" },
    { path = "core/trends.lua", size_bytes = 1791, hash = "d01a6948" },
    { path = "core/turbine_ctrl.lua", size_bytes = 1266, hash = "a0681bf2" },
    { path = "core/ui.lua", size_bytes = 8614, hash = "0dbff3eb" },
    { path = "core/ui_router.lua", size_bytes = 6305, hash = "e626dd67" },
    { path = "core/utils.lua", size_bytes = 7801, hash = "a425d6c7" },
    { path = "release.lua", size_bytes = 207, hash = "8994add5" },
    { path = "services/alert_service.lua", size_bytes = 10068, hash = "f5ad1d30" },
    { path = "services/comms_service.lua", size_bytes = 5599, hash = "1c80d077" },
    { path = "services/control_service.lua", size_bytes = 419, hash = "01a44c98" },
    { path = "services/discovery_service.lua", size_bytes = 2445, hash = "4a26ac38" },
    { path = "services/service_manager.lua", size_bytes = 3122, hash = "aa167732" },
    { path = "services/telemetry_service.lua", size_bytes = 1748, hash = "980faa0d" },
    { path = "services/ui_service.lua", size_bytes = 1512, hash = "bb5eed3f" },
    { path = "start.lua", size_bytes = 1541, hash = "f8c99b78" },
    { path = "shared/build_info.lua", size_bytes = 874, hash = "19ff720f" },
    { path = "shared/colors.lua", size_bytes = 332, hash = "445d12af" },
    { path = "shared/constants.lua", size_bytes = 1384, hash = "db560e96" },
    { path = "shared/health_codes.lua", size_bytes = 336, hash = "e1d7e466" },
    { path = "shared/telemetry_schema.lua", size_bytes = 680, hash = "42e7fe19" }
  },
  roles = {
    master = {
      { path = "master/config.lua", size_bytes = 7578, hash = "09301620" },
      { path = "master/main.lua", size_bytes = 37158, hash = "769eaf60" },
      { path = "master/profiles.lua", size_bytes = 164, hash = "9068a725" },
      { path = "master/startup_sequencer.lua", size_bytes = 8165, hash = "fbe5786a" },
      { path = "master/ui/alarms.lua", size_bytes = 1245, hash = "ab00070b" },
      { path = "master/ui/alerts.lua", size_bytes = 25335, hash = "746207f8" },
      { path = "master/ui/energy.lua", size_bytes = 4345, hash = "853d19c8" },
      { path = "master/ui/multiview.lua", size_bytes = 11565, hash = "2bceb16e" },
      { path = "master/ui/overview.lua", size_bytes = 4525, hash = "89e0cb55" },
      { path = "master/ui/resources.lua", size_bytes = 5534, hash = "0447e76b" },
      { path = "master/ui/rt_dashboard.lua", size_bytes = 2824, hash = "6ca4b11e" },
      { path = "master/ui/widgets.lua", size_bytes = 775, hash = "aafe7d4a" }
    },
    rt = {
      { path = "nodes/rt/config.lua", size_bytes = 4425, hash = "8c4b3c3f" },
      { path = "nodes/rt/main.lua", size_bytes = 98530, hash = "57914dd6" }
    },
    energy = {
      { path = "nodes/energy/config.lua", size_bytes = 4614, hash = "7b0f8089" },
      { path = "nodes/energy/main.lua", size_bytes = 48678, hash = "e3897d76" }
    },
    water = {
      { path = "nodes/water/config.lua", size_bytes = 3612, hash = "4630013f" },
      { path = "nodes/water/main.lua", size_bytes = 24508, hash = "6aeea5c8" }
    },
    fuel = {
      { path = "nodes/fuel/config.lua", size_bytes = 3523, hash = "35c40abf" },
      { path = "nodes/fuel/main.lua", size_bytes = 24231, hash = "110ab895" }
    },
    reprocessing = {
      { path = "nodes/reprocessor/config.lua", size_bytes = 3319, hash = "f1fda934" },
      { path = "nodes/reprocessor/main.lua", size_bytes = 24065, hash = "1d923219" }
    }
  }
}
