local telemetry_schema = {
  version = 1,
  base = {
    node_id = "string",
    role = "string",
    proto_ver = "table",
    build = "table",
    health = "table",
    bindings = "table",
    devices = "table"
  },
  roles = {
    ENERGY = {
      total = "table",
      matrices = "table",
      storages = "table"
    },
    RT = {
      turbines = "table",
      reactors = "table",
      control_mode = "string",
      ramp_state = "table"
    },
    FUEL = {
      sources = "table"
    },
    WATER = {
      total_water = "number",
      buffers = "table"
    },
    REPROCESSOR = {
      buffers = "table",
      standby = "boolean"
    }
  }
}

return telemetry_schema
