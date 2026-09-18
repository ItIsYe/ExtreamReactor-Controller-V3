-- Regression test (log audit, 2026-09-18): registry:sync() marked a
-- no-longer-seen device with missing=true but NEVER removed it from
-- self.state.devices/order/name_index. In this world, a turbine/reactor
-- multiblock's raw peripheral name (e.g. "BigReactors-Turbine_244") shifts
-- on practically every server restart (CC:Tweaked reassigns the internal
-- registration id after a world reload) -- every restart therefore
-- registered a BRAND NEW device entry (new name -> new hashed id) while
-- the old entry sat forever as "missing=true", never reclaimed.
-- Unbounded over a long play session: registry_rt_<node>.json grows by the
-- full device count on every single restart, and every pairs(devices)/
-- list() iteration (get_summary, get_bound_devices, every status query)
-- gets linearly slower.
--
-- Fix: sync() now purges an entry once it has been missing for at least
-- MISSING_RETENTION_MS (30 minutes) -- long enough that a genuinely
-- transient disconnect (network blip, brief power loss) never gets
-- purged, since sync() flips missing back to false the moment the device
-- reappears in a later scan.

local writes = 0
local files = {}
_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode == "r" then
      if files[path] == nil then return nil end
      return { readAll = function() return files[path] end, close = function() end }
    end
    return {
      write = function(data) files[path] = data writes = writes + 1 end,
      close = function() end
    }
  end,
  getDir = function() return "" end,
  makeDir = function() end,
  move = function(old_path, new_path) files[new_path] = files[old_path] files[old_path] = nil end,
  delete = function(path) files[path] = nil end,
}
_G.textutils = {
  serialize = function(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
      out[#out + 1] = tostring(k) .. "=" .. textutils.serialize(value[k])
    end
    return "{" .. table.concat(out, ";") .. "}"
  end,
  unserialize = function() return nil end,
}
_G.os = _G.os or {}
-- Controllable fake clock (ms) instead of comms_test's auto-incrementing
-- stub -- this test needs to jump time forward by exactly the retention
-- window between sync() calls.
local fake_now = 1000000
os.epoch = function() return fake_now end

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local registry = require("core.registry").new({ node_id = "NODE-1", role = "test", path = "/tmp/registry_purge_test" })

local function assert_true(v, m) if not v then error(m or "assert_true failed") end end
local function assert_eq(a, e, m) if a ~= e then error((m or "eq") .. ": expected=" .. tostring(e) .. " actual=" .. tostring(a)) end end

-- Boot 1: "BigReactors-Turbine_244" is seen.
registry:sync({
  { name = "BigReactors-Turbine_244", type = "BigReactors-Turbine", kind = "turbine", bound = true, methods = { "setFluidFlowRate" } }
})
assert_eq(#registry:list(), 1, "first boot should register exactly one device")
local old_id = registry:list()[1].id

-- A short while later (well under the retention window), the world
-- reloads and the SAME physical turbine now reports under a shifted name
-- ("_245" instead of "_244") -- a brand new device entry is created, and
-- the old one is marked missing, but must NOT be purged yet (still a
-- recent disconnect, not a confirmed-gone device).
fake_now = fake_now + 5 * 60 * 1000 -- +5 minutes
registry:sync({
  { name = "BigReactors-Turbine_245", type = "BigReactors-Turbine", kind = "turbine", bound = true, methods = { "setFluidFlowRate" } }
})
assert_eq(#registry:list(), 2, "renamed device must register as a new entry alongside the still-recent old one")
local found_old = false
for _, entry in ipairs(registry:list()) do
  if entry.id == old_id then found_old = true assert_true(entry.missing == true, "old entry must be marked missing") end
end
assert_true(found_old, "old entry must survive a recent disconnect (well under the retention window)")

-- Time keeps passing across several more restarts with no sign of the old
-- name ever coming back -- once missing for >= MISSING_RETENTION_MS
-- (30 minutes) total, the stale entry must be purged so the registry file
-- does not grow without bound over a long play session.
fake_now = fake_now + 30 * 60 * 1000 -- +30 more minutes (35 min since old entry was last seen)
registry:sync({
  { name = "BigReactors-Turbine_245", type = "BigReactors-Turbine", kind = "turbine", bound = true, methods = { "setFluidFlowRate" } }
})
assert_eq(#registry:list(), 1, "an entry missing for >= the retention window must be purged, not accumulate forever")
assert_eq(registry:list()[1].name, "BigReactors-Turbine_245", "the surviving entry must be the currently-seen device")

-- A device that reappears BEFORE the retention window elapses must not be
-- purged and must flip back to missing=false, proving the purge only
-- catches confirmed-gone devices, never a transient blip.
fake_now = fake_now + 60 * 1000
registry:sync({}) -- briefly disappears
fake_now = fake_now + 60 * 1000
registry:sync({
  { name = "BigReactors-Turbine_245", type = "BigReactors-Turbine", kind = "turbine", bound = true, methods = { "setFluidFlowRate" } }
})
assert_eq(#registry:list(), 1, "a brief reappearance must not create a duplicate or lose the entry")
assert_true(registry:list()[1].missing == false, "a device seen again must be marked not-missing")

print("core_registry_missing_device_purge_test.lua: ok")
