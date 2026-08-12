package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.mockup_ui'] = {}
package.loaded['nodes.fuel.ui_completion'] = nil

local completion = require('nodes.fuel.ui_completion')
local devices = { last_scan_ts = 1 }

local function state(payload)
  return completion.compute_view_state({ payload = payload }, devices, payload.reserve, payload.minimum_reserve)
end

local base = {
  reserve = 4000,
  minimum_reserve = 2000,
  master_connected = true,
  bindings = { storage = 1 },
  routing_load_status = { ok = true },
  valve_summary = { total = 2, offline = 0, stale = 0 },
  logistics = {
    enabled = true,
    bridge = 'meBridge_0',
    reactors = {
      { label = 'R1', reactor_id = 'rt-1-reactor-0', connected = true, fuel_pct = 50, fuel_data_state = 'FRESH', route_state = 'ROUTE_READY', operational_state = 'READY', delivery_state = 'READY' },
      { label = 'R2', reactor_id = 'rt-2-reactor-0', connected = true, fuel_pct = 25, fuel_data_state = 'FRESH', route_state = 'ROUTE_READY', operational_state = 'READY', delivery_state = 'READY' },
    },
  },
}

assert(state(base).code == 'READY')

base.logistics.bridge = nil
assert(state(base).code == 'NO_ME_BRIDGE', 'missing ME Bridge must block READY')
base.logistics.bridge = 'meBridge_0'

base.logistics.reactors[2].operational_state = 'BLOCKED'
base.logistics.reactors[2].route_state = 'VALVE_OFFLINE'
local blocked = state(base)
assert(blocked.code == 'LOGISTICS_BLOCKED', 'blocked per-reactor route must block READY')
assert(blocked.detail:find('R2', 1, true))
base.logistics.reactors[2].operational_state = 'READY'
base.logistics.reactors[2].route_state = 'ROUTE_READY'

base.logistics.reactors[2].fuel_pct = nil
base.logistics.reactors[2].fuel_data_state = 'STALE'
base.logistics.reactors[2].operational_state = 'STALE'
assert(state(base).code == 'DATA_STALE', 'STALE reactor data must be explicit and block READY')

base.logistics.reactors[2].fuel_data_state = 'MISSING'
base.logistics.reactors[2].operational_state = 'MISSING'
assert(state(base).code == 'DATA_MISSING', 'MISSING reactor data must be distinct from STALE')

base.logistics.enabled = false
assert(state(base).code == 'LOGISTICS_DISABLED', 'disabled logistics must not be displayed as READY/AUTO')

base.logistics.enabled = true
base.logistics.reactors[2].fuel_pct = 25
base.logistics.reactors[2].fuel_data_state = 'FRESH'
base.logistics.reactors[2].operational_state = 'READY'
base.logistics.current_request = { reactor_id = 'rt-2-reactor-0', label = 'R2', state = 'delivering' }
local delivering = state(base)
assert(delivering.code == 'DELIVERING')
assert(delivering.detail == 'R2', 'delivery detail must be human-readable, not table:0x...')

base.logistics.current_request = nil
base.master_connected = false
assert(state(base).code == 'NO_FRESH_RT_DATA')

base.master_connected = true
base.valve_summary.stale = 1
assert(state(base).code == 'VALVE_OFFLINE', 'stale VALVE connectivity must not be considered operational')

print('fuel_ui_view_state_regression_test.lua: ok')
