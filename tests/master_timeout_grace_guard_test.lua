local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local source = read("xreactor/master/main.lua")

local required = {
  "local down_grace_ms = (config.comms and config.comms.peer_down_grace_s or 0) * 1000",
  "should_mark_down = last_seen and (now - last_seen > (timeout_ms + down_grace_ms))",
  "node.health.reasons = node.health.reasons or {}",
  "node.health.reasons[health.reasons.COMMS_DOWN] = true"
}

for _, snippet in ipairs(required) do
  if not source:find(snippet, 1, true) then
    error("missing master timeout grace guard snippet: " .. tostring(snippet))
  end
end

print("master_timeout_grace_guard_test.lua: ok")
