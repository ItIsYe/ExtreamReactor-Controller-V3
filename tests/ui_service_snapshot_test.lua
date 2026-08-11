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

-- A resize changes geometry even when the data snapshot is identical. It
-- must bypass both the regular interval and snapshot suppression so footer
-- text and touch zones are rebuilt together.
local resize_renders = 0
local resize_service = ui_service.new({
  interval = 100,
  force_interval = 100,
  snapshot = function() return "same" end,
  render = function() resize_renders = resize_renders + 1 end,
})
resize_service:tick(nil, { "monitor_resize", "monitor_0" })
if resize_renders ~= 1 then
  error("monitor_resize must force an immediate geometry redraw")
end
resize_service:tick(nil, { "term_resize" })
if resize_renders ~= 2 then
  error("term_resize must force an immediate geometry redraw")
end

-- A router-completed navigation has already drawn from its cached model.
-- Rebuilding expensive role/peripheral data in the same event would keep
-- the event loop blocked and delay the following touch.
local model_builds, navigation_renders, inputs = 0, 0, 0
local navigation_service = ui_service.new({
  interval = 0,
  force_interval = 0,
  build_model = function()
    model_builds = model_builds + 1
    return { snapshot = "stable" }
  end,
  render = function() navigation_renders = navigation_renders + 1 end,
  handle_input = function()
    inputs = inputs + 1
    return true, "page_navigation_redrawn"
  end,
})
navigation_service:tick()
if model_builds ~= 1 or navigation_renders ~= 1 then
  error("navigation service must establish one initial model")
end
navigation_service:tick(nil, { "monitor_touch", "monitor_0", 40, 20 })
if inputs ~= 1 then error("navigation input must be delivered exactly once") end
if model_builds ~= 1 or navigation_renders ~= 1 then
  error("completed navigation must not synchronously rebuild the role model")
end

print("ui_service_snapshot_test.lua: ok")
