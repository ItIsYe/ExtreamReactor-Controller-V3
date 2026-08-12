-- tests/auto_update_quiesce_timeout_budget_test.lua
--
-- Regression test: installer/auto_update.lua's QUIESCE_TIMEOUT_S (the
-- deadline request_and_await_quiesce() waits for RUNTIME_STOPPED before
-- giving up and letting the role keep running) must stay comfortably
-- larger than redstone_router.lua's SAFETY_CONFIRM_TIMEOUT_MS -- the
-- per-attempt budget FUEL/REPROCESSOR's begin_quiesce()/poll_quiesce()
-- uses to wait for a wireless VALVE node's BLOCKED ACK before re-sending.
--
-- Root cause this guards against: a previous QUIESCE_TIMEOUT_S of 20s left
-- barely any margin over a SINGLE 15s confirmation attempt -- any ACK
-- retry, or a valve simply taking a few seconds to reply, reliably blew
-- the outer deadline. The role never actually got a fair chance to finish
-- quiescing; auto_update.lua reset the handshake and the whole periodic
-- cycle (up to 120s later) started over, indefinitely, without ever
-- installing (reported symptom: "quiesce timeout -- role stays active,
-- update stays pending, then starts over").

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local repo_root = os.getenv("REPO_ROOT") or "."

local auto_update_src = read_file(repo_root .. "/xreactor/installer/auto_update.lua")
local quiesce_timeout_s = tonumber(auto_update_src:match("QUIESCE_TIMEOUT_S%s*=%s*(%d+)"))
if not quiesce_timeout_s then
  error("could not find QUIESCE_TIMEOUT_S in installer/auto_update.lua")
end

local router_src = read_file(repo_root .. "/xreactor/nodes/fuel/redstone_router.lua")
local safety_confirm_timeout_ms = tonumber(router_src:match("SAFETY_CONFIRM_TIMEOUT_MS%s*=%s*(%d+)"))
if not safety_confirm_timeout_ms then
  error("could not find SAFETY_CONFIRM_TIMEOUT_MS in nodes/fuel/redstone_router.lua")
end

-- Require room for at least 3 full confirmation rounds (initial attempt
-- plus at least two retries) -- one attempt alone is not a safety margin.
local min_required_s = math.ceil(3 * safety_confirm_timeout_ms / 1000)
if quiesce_timeout_s < min_required_s then
  error(string.format(
    "QUIESCE_TIMEOUT_S=%ds leaves no real margin over SAFETY_CONFIRM_TIMEOUT_MS=%dms "
      .. "(need >= %ds for 3 confirmation rounds) -- FUEL/REPROCESSOR quiesce will "
      .. "reliably time out under normal wireless ACK latency",
    quiesce_timeout_s, safety_confirm_timeout_ms, min_required_s))
end

print("auto_update_quiesce_timeout_budget_test.lua: ok")
