return {
  shared = {
    prefixes = {
      "xreactor/core/",
      "xreactor/shared/",
      "xreactor/installer/"
    },
    files = {}
  },
  services = {
    service_manager = "xreactor/services/service_manager.lua",
    comms = "xreactor/services/comms_service.lua",
    discovery = "xreactor/services/discovery_service.lua",
    telemetry = "xreactor/services/telemetry_service.lua",
    ui = "xreactor/services/ui_service.lua",
    control = "xreactor/services/control_service.lua",
    alert = "xreactor/services/alert_service.lua"
  },
  adapters = {
    monitor = "xreactor/adapters/monitor.lua",
    reactor = "xreactor/adapters/reactor.lua",
    turbine = "xreactor/adapters/turbine.lua",
    energy = "xreactor/adapters/energy_storage.lua",
    matrix = "xreactor/adapters/induction_matrix.lua"
  },
  roles = {
    MASTER = {
      files = {
        "xreactor/master/config.lua",
        "xreactor/master/startup_sequencer.lua",
        "xreactor/master/profiles.lua",
        "xreactor/master/main.lua",
        "xreactor/master/ui/alarms.lua",
        "xreactor/master/ui/resources.lua",
        "xreactor/master/ui/rt_dashboard.lua",
        "xreactor/master/ui/overview.lua",
        "xreactor/master/ui/alerts.lua",
        "xreactor/master/ui/energy.lua",
        "xreactor/master/ui/multiview.lua",
        "xreactor/master/ui/widgets.lua"
      },
      services = { "service_manager", "comms", "alert", "telemetry", "ui" },
      adapters = { "monitor" }
    },
    RT = {
      files = {
        "xreactor/nodes/rt/config.lua",
        "xreactor/nodes/rt/main.lua"
      },
      services = { "service_manager", "comms", "discovery", "telemetry", "control" },
      adapters = { "monitor", "reactor", "turbine" }
    },
    ENERGY = {
      files = {
        "xreactor/nodes/energy/config.lua",
        "xreactor/nodes/energy/main.lua"
      },
      services = { "service_manager", "comms", "discovery", "telemetry", "ui", "control" },
      adapters = { "monitor", "energy", "matrix" }
    },
    WATER = {
      files = {
        "xreactor/nodes/water/config.lua",
        "xreactor/nodes/water/main.lua"
      },
      services = { "service_manager", "comms", "discovery", "telemetry", "ui" },
      adapters = { "monitor" }
    },
    FUEL = {
      files = {
        "xreactor/nodes/fuel/config.lua",
        "xreactor/nodes/fuel/main.lua"
      },
      services = { "service_manager", "comms", "discovery", "telemetry", "ui" },
      adapters = { "monitor" }
    },
    REPROCESSOR = {
      files = {
        "xreactor/nodes/reprocessor/config.lua",
        "xreactor/nodes/reprocessor/main.lua"
      },
      services = { "service_manager", "comms", "discovery", "telemetry", "ui" },
      adapters = { "monitor" }
    }
  }
}
