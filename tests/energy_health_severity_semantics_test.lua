package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local status_payload = require('nodes.energy.status_payload')
local health = require('core.health')

local function build(dev)
  local builder = status_payload.new({
    now_ms = function() return 1000 end,
    config = {}, utils = {}, health = health,
    registry = { get_summary=function() return {} end, get_devices_by_kind=function() return {} end, get_diagnostics=function() return {} end },
    devices = dev, energy_health = {},
    read_storage_stats = function() return { stored=10, capacity=100, input=1, output=1, stores={}, freshness_ms=0, stale=false } end,
    read_matrix_stats = function() return { total={stored=0, capacity=0, input=0, output=0, percent=0}, matrices={}, freshness_ms=0, stale=false } end,
    is_master_connected = function() return true end,
    log = function() end
  })
  return builder.build_status_payload_uncached({})
end

local payload = build({ monitor=nil, storages={}, matrix_groups={{id='m1'}}, bound_storage_names={} })
if payload.health.status ~= health.status.OK then error('NO_MONITOR/NO_STORAGE should not degrade when matrix core is present') end

payload = build({ monitor=true, storages={{id='s1'}}, matrix_groups={}, bound_storage_names={'s1'} })
if payload.health.status ~= health.status.DEGRADED then error('NO_MATRIX must remain degraded') end

print('energy_health_severity_semantics_test.lua: ok')
