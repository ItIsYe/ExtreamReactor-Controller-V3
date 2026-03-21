_G.os = _G.os or {}
local now = 0
os.epoch = function()
  now = now + 500
  return now
end

_G.textutils = {
  serialize = function(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for k, v in pairs(value) do
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(parts)
    return table.concat(parts, ";")
  end
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local ui_service = require("services.ui_service")

local renders = 0
local snapshot_value = "same"
local service = ui_service.new({
  interval = 0.5,
  force_interval = 2,
  snapshot = function() return snapshot_value end,
  render = function() renders = renders + 1 end
})

service:tick()
if renders ~= 1 then
  error("initial render expected")
end

service:tick()
service:tick()
if renders ~= 1 then
  error("unchanged snapshot should not redraw before fallback interval")
end

snapshot_value = "changed"
service:tick()
if renders ~= 2 then
  error("changed snapshot should trigger redraw")
end

service:tick(nil, { "monitor_touch" })
if renders ~= 3 then
  error("interactive events should remain responsive")
end

print("ui_service_snapshot_test.lua: ok")
