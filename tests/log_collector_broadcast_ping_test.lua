-- tests/log_collector_broadcast_ping_test.lua
--
-- Regression test: the LOG_COLLECTOR must broadcast an unaddressed LOG_PING
-- presence beacon (see core/utils.lua's logger_reachable()) so every other
-- node can passively confirm it's online without first sending a real log
-- line. nodes/log_collector/main.lua has heavy boot-time side effects and
-- cannot be require()'d -- broadcast_ping() is self-contained (only needs
-- stats/computer_node_id/now_ms/CHANNEL), so it's extracted by marker and
-- run in isolation (same technique as
-- log_collector_flush_bucket_send_ack_forward_decl_test.lua).

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local SOURCE = read("xreactor/nodes/log_collector/main.lua")

local START_MARKER = "local function broadcast_ping()"
local END_MARKER = "\nend\n\n-- \xe2\x94\x80\xe2\x94\x80 Self log"

local start_pos = SOURCE:find(START_MARKER, 1, true)
assert(start_pos, "broadcast_ping() definition not found")
local end_pos = SOURCE:find(END_MARKER, start_pos, true)
assert(end_pos, "end of broadcast_ping() not found")

-- END_MARKER starts at the "\n" right before the function's closing "end"
-- (len 4: "\n"+"end") -- include exactly that "end", nothing past it.
local chunk_src = SOURCE:sub(start_pos, end_pos + 3) .. "\nreturn { broadcast_ping = broadcast_ping }\n"

local transmitted = {}
local function make_modem(via)
  return { transmit = function(ch, reply, msg) transmitted[#transmitted + 1] = { ch = ch, reply = reply, msg = msg, via = via }; return true end }
end
local env = setmetatable({
  stats = {
    ping_sent = 0,
    modems = {
      { wireless = false, modem = make_modem("wired") },
      { wireless = true, modem = make_modem("wireless") },
    },
  },
  computer_node_id = function() return "LOG-1" end,
  now_ms = function() return 12345 end,
  CHANNEL = 6503,
}, { __index = _G })

local fn = assert(load(chunk_src, "=log_collector_broadcast_ping_test", "t", env))
local mod = fn()

mod.broadcast_ping()

assert(#transmitted == 1, "broadcast_ping() must transmit exactly once (stop at the first successful modem), got " .. #transmitted)
assert(transmitted[1].ch == 6503 and transmitted[1].reply == 6503, "must transmit on the LOG channel")
local msg = transmitted[1].msg
assert(msg.type == "LOG_PING", "expected a LOG_PING message, got: " .. tostring(msg.type))
assert(msg.collector_node == "LOG-1", "expected the collector's own node id")
assert(msg.ts == 12345, "expected the current timestamp")
assert(env.stats.ping_sent == 1, "expected stats.ping_sent to be incremented")

-- Prefers the wireless modem when both are present (same convention as
-- send_ack()) -- the FIRST stats.modems entry here is wired, so a correct
-- implementation must have reordered to try the wireless one first.
assert(transmitted[1].via == "wireless", "expected the wireless modem to be tried first, got: " .. tostring(transmitted[1].via))

print("log_collector_broadcast_ping_test.lua: ok")
