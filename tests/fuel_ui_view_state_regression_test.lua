package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.mockup_ui'] = {}
package.loaded['nodes.fuel.ui_pages'] = nil

local ui_pages = require('nodes.fuel.ui_pages')
local devices = { last_scan_ts = 1 }

local function state(payload)
  return ui_pages.compute_view_state({ payload = payload }, devices, payload.reserve, payload.minimum_reserve)
end

local base = {
  reserve = 4000,
  minimum_reserve = 2000,
  master_connected = true,
  bindings = { storage = 1 },
  routing_load_status = { ok = true },
  valve_summary = { total = 0, offline = 0 },
  logistics = {
    enabled = true,
    bridge = 'meBridge_0',
    reactors = {
      { label = 'R1', reactor_id = 'rt-1-reactor-0', connected = true, fuel_pct = 50 },
      { label = 'R2', reactor_id = 'rt-2-reactor-0', connected = true, fuel_pct = 25 },
    },
  },
}

assert(state(base).code == 'READY')

base.logistics.reactors[2].fuel_pct = nil
local stale = state(base)
assert(stale.code == 'NO_FRESH_RT_DATA', 'missing/stale per-reactor fuel data must block READY')
assert(stale.detail:find('R2', 1, true), 'state must identify the affected reactor')

base.logistics.enabled = false
assert(state(base).code == 'LOGISTICS_DISABLED', 'disabled logistics must not be displayed as READY/AUTO')

base.logistics.enabled = true
base.logistics.reactors[2].fuel_pct = 25
base.logistics.current_request = { reactor_id = 'rt-2-reactor-0', label = 'R2', state = 'delivering' }
local delivering = state(base)
assert(delivering.code == 'DELIVERING')
assert(delivering.detail == 'R2', 'delivery detail must be human-readable, not table:0x...')

base.logistics.current_request = nil
base.master_connected = false
assert(state(base).code == 'NO_FRESH_RT_DATA')

print('fuel_ui_view_state_regression_test.lua: ok')
