local writes = 0
local files = {}

_G.fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode == "r" then
      if files[path] == nil then
        return nil
      end
      return {
        readAll = function() return files[path] end,
        close = function() end
      }
    end
    return {
      write = function(data)
        files[path] = data
        writes = writes + 1
      end,
      close = function() end
    }
  end,
  getDir = function() return "" end,
  makeDir = function() end,
  getSize = function(path) return #(files[path] or "") end,
  move = function(old_path, new_path) files[new_path] = files[old_path] files[old_path] = nil end,
  delete = function(path) files[path] = nil end,
}

_G.bit32 = _G.bit32 or {
  band = function(a, b) return a & b end,
  bxor = function(a, b) return a ~ b end,
  lshift = function(a, b) return a << b end,
}
_G.textutils = {
  serialize = function(value)
    local function encode(v)
      if type(v) ~= "table" then return tostring(v) end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local out = {}
      for _, key in ipairs(keys) do
        out[#out + 1] = tostring(key) .. "={" .. encode(v[key]) .. "}"
      end
      return table.concat(out, ",")
    end
    return encode(value)
  end,
  unserialize = function() return nil end,
}
_G.os = _G.os or {}
local now = 0
os.epoch = function() now = now + 1000 return now end

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local registry = require("core.registry")

local reg = registry.new({ node_id = "NODE-1", role = "test", path = "/tmp/registry" })
reg:sync({
  { name = "left", type = "monitor", kind = "monitor", bound = true, methods = { "write" } }
})
local first_writes = writes
reg:sync({
  { name = "left", type = "monitor", kind = "monitor", bound = true, methods = { "write" } }
})
if writes ~= first_writes then
  error("unchanged discovery cycle should not trigger another save")
end

reg:update_status(reg:list()[1].id, "WARN", "changed")
if writes <= first_writes then
  error("meaningful registry changes should still persist")
end

print("registry_io_test.lua: ok")
