package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

package.loaded["nodes.energy.discovery_runtime"] = nil
_G.os = _G.os or {}
_G.os.epoch = _G.os.epoch or function() return 0 end

local runtime = require("nodes.energy.discovery_runtime")

local discovered_devices = {
  monitor = nil,
  monitor_name = nil,
  storages = {},
  matrices = {},
  matrix_groups = {},
  adapters = { storages = {}, matrices = {} },
  matrix_identity_cache = {},
  topology_signature = "",
  discovery_failed = false
}

local registry_state = {
  storage = {
    { id = "S-1", alias = "Cube A", name = "cube_0" },
    { id = "S-2", alias = "Cube B", name = "cube_1" }
  },
  matrix = {
    { id = "M-1", alias = "Matrix A", name = "matrix_0" },
    { id = "M-2", alias = "Matrix B", name = "matrix_1" }
  }
}

local registry = {
  sync = function() end,
  get_order_index = function() return {} end,
  get_bound_devices = function(_, kind) return registry_state[kind] or {} end,
  get_devices_by_kind = function() return {} end,
  get_summary = function()
    return { kinds = { storage = { bound = 2 }, matrix = { bound = 2 } } }
  end,
  state = { load_error = nil }
}

local discovery = runtime.new({
  config = {
    matrix = nil,
    matrix_names = {},
    matrix_aliases = {},
    cubes = {},
    storage_filters = { include_names = nil, exclude_names = {}, prefer_names = {} },
    monitor = { preferred_name = nil, strategy = "largest" },
    ui_scale = 0.5
  },
  debug_enabled = false,
  utils = { safe_get_methods = function() return {} end },
  peripheral = {
    getNames = function() return { "cube_0", "cube_1", "matrix_0", "matrix_1" } end,
    getType = function(name)
      if name:find("matrix", 1, true) then return "modem_matrix" end
      return "modem_storage"
    end,
    isPresent = function() return true end
  },
  monitor_adapter = { find = function() return nil end },
  matrix_adapter = {
    detect = function(name)
      if not name:find("matrix", 1, true) then return nil end
      return { name = name, getType = function() return "matrix" end, getMethodList = function() return {} end }
    end,
    group_ports = function(items)
      if #items == 0 then return {} end
      return { { key = "k", representative = items[1], ports = { items[1] } } }
    end
  },
  storage_adapter = {
    detect = function(name)
      if not name:find("cube", 1, true) then return nil end
      return { name = name, getType = function() return "storage" end, getMethodList = function() return {} end }
    end
  },
  discovery_log = { build_signature = function() return "sig" end, should_log_details = function() return false end },
  registry = registry,
  devices = discovered_devices,
  log = function() end
})

discovery.discover()

if #discovered_devices.storages ~= 1 then
  error("expected single storage binding, got " .. tostring(#discovered_devices.storages))
end
if #discovered_devices.matrices ~= 1 then
  error("expected single matrix binding, got " .. tostring(#discovered_devices.matrices))
end

print("energy_single_binding_model_test.lua: ok")
