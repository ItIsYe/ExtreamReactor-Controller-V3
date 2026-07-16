local writes = 0
_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
  getDir = function() return "" end,
  makeDir = function() end,
  move = function() end,
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
-- bit32 (band/bxor/lshift) is native in Lua 5.2 (the CI test-runner
-- interpreter, see tools/run_lua_tests.sh) and used internally by
-- core/registry.lua's hash() -- no shim needed here. An earlier version of
-- this fallback used Lua 5.3-only native bitwise operators (&, ~, <<),
-- which made the whole file fail to even parse under lua5.2.
_G.os = _G.os or {}
local now = 0
os.epoch = function() now = now + 1000 return now end
_G.peripheral = {
  getType = function() return "monitor" end,
}
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
local utils = require("core.utils")
utils.write_config = function(_, _) writes = writes + 1 end
local registry = require("core.registry").new({ path = "/tmp/registry_test" })
registry:save()
if writes ~= 0 then error("clean registry should not save") end
registry:sync({})
if writes ~= 0 then error("unchanged sync should not save") end
local entry = select(1, registry:register("left", { type = "monitor", methods = { "touch" }, found = true, bound = true }))
registry._dirty = true
registry._persist_dirty = false
registry:save()
if writes ~= 0 then error("non-persist dirty state should not write") end
registry:update_status(entry.id, "OK")
if writes ~= 1 then error("persisted status change should save exactly once") end
print("registry_dirty_test.lua: ok")
