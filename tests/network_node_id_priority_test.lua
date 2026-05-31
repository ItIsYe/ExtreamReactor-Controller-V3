package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

package.loaded["core.network"] = nil
package.loaded["core.utils"] = nil
package.loaded["core.protocol"] = nil
package.loaded["shared.constants"] = nil

_G.fs = {
  _files = {},
  exists = function(path) return _G.fs._files[path] ~= nil end,
  open = function(path, mode)
    if mode == "r" then
      local value = _G.fs._files[path]
      if value == nil then return nil end
      return {
        readAll = function() return value end,
        close = function() end
      }
    end
    if mode == "w" then
      return {
        write = function(content) _G.fs._files[path] = content end,
        close = function() end
      }
    end
    return nil
  end,
  getDir = function(path) return path:match("(.+)/[^/]+$") or "" end,
  makeDir = function() end
}

_G.os = {
  getComputerID = function() return 42 end,
  getComputerLabel = function() return nil end,
  pullEvent = function() return "terminate" end
}

_G.peripheral = {
  getNames = function() return {} end,
  isPresent = function() return false end
}

local network = require("core.network")

local net = network.init({ role = "ENERGY", node_id = "ENERGY-1" })
if net.id ~= "node-42" then
  error("expected generated node id when config uses role default, got " .. tostring(net.id))
end

_G.fs._files["/xreactor/config/node_id.txt"] = "persisted-abc"
local net2 = network.init({ role = "ENERGY", node_id = "ENERGY-1" })
if net2.id ~= "persisted-abc" then
  error("expected persisted node id to win over config defaults")
end

print("network_node_id_priority_test.lua: ok")
