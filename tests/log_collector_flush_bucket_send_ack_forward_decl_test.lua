-- tests/log_collector_flush_bucket_send_ack_forward_decl_test.lua
--
-- Pflicht-Test fuer LOG-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md). Bestaetigt per echtem Logauszug (xreactor_logs/
-- log_collector/*.log, 2026-07-16): "loop crashed on event=timer:
-- ...log_collector/main.lua:674: attempt to call global 'send_ack' (a nil
-- value)", deterministisch bei JEDEM erfolgreichen flush_bucket()-Durchlauf.
--
-- Ursache: flush_bucket() wurde als Funktionsliteral ("flush_bucket =
-- function(path) ... end") bereits VOR "local function send_ack(...)"
-- (weiter unten im selben Chunk) kompiliert. Lua loest freie Variablen beim
-- Kompilieren eines Funktionsliterals anhand des zu diesem Zeitpunkt
-- SICHTBAREN lexikalischen Scopes auf, nicht erst beim spaeteren Ausfuehren
-- -- ohne eine zu diesem Zeitpunkt bereits deklarierte lokale "send_ack"
-- fiel der Aufruf in flush_bucket() auf eine GLOBALE Variable dieses Namens
-- zurueck, die nirgends gesetzt wird. Fix: "send_ack" wird jetzt zusammen
-- mit flush_bucket/flush_due vorwaertsdeklariert (lokale Variable VOR
-- flush_bucket()'s Definition), send_ack() selbst wird per Zuweisung statt
-- "local function" gesetzt (identisches Muster wie flush_bucket/flush_due).
--
-- nodes/log_collector/main.lua hat schwere Boot-Zeit-Seiteneffekte und kann
-- nicht per require() instanziiert werden -- dieser Test extrahiert daher
-- den echten Quelltext (Vorwaertsdeklaration bis zum Ende von send_ack(),
-- inklusive der echten flush_bucket()-Definition dazwischen) per
-- String-Marker und fuehrt ihn per load() in einer isolierten, gemockten
-- Umgebung aus.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local SOURCE = read("xreactor/nodes/log_collector/main.lua")

local START_MARKER = "local flush_bucket\nlocal flush_due\nlocal send_ack"
local END_MARKER = "\nsend_ack = function(payload, status)"
local send_ack_end_marker = "\n  end\nend\n\n-- \xe2\x94\x80\xe2\x94\x80 Self log"

local start_pos = SOURCE:find(START_MARKER, 1, true)
assert(start_pos, "forward-declaration block not found")
local mid_pos = SOURCE:find(END_MARKER, start_pos, true)
assert(mid_pos, "send_ack assignment not found")
local end_pos = SOURCE:find(send_ack_end_marker, mid_pos, true)
assert(end_pos, "end of send_ack() not found")

-- flush_bucket() (the real, unmodified body) lives BETWEEN the forward
-- declarations and send_ack's own definition -- pull it out separately so
-- we can splice it back in between them, exactly reproducing the original
-- file's compile order (forward decls -> flush_bucket literal -> send_ack
-- assignment), which is the exact condition the bug depended on.
local FLUSH_BUCKET_START = "flush_bucket = function(path)"
local FLUSH_BUCKET_END_MARKER = "\n  stats.pending_writes[path] = nil\nend\n"
local fb_start = SOURCE:find(FLUSH_BUCKET_START, start_pos, true)
assert(fb_start, "flush_bucket definition not found")
local fb_end = SOURCE:find(FLUSH_BUCKET_END_MARKER, fb_start, true)
assert(fb_end, "end of flush_bucket() not found")
local flush_bucket_block = SOURCE:sub(fb_start, fb_end + #FLUSH_BUCKET_END_MARKER - 1)

local decls_block = SOURCE:sub(start_pos, mid_pos - 1)
local send_ack_block = SOURCE:sub(mid_pos + 1, end_pos + #send_ack_end_marker - 1)
-- Trim the trailing "-- Self log" comment header we only used as an anchor.
send_ack_block = send_ack_block:gsub("\n%-%- \xe2\x94\x80\xe2\x94\x80 Self log.*$", "")

local chunk_src = decls_block .. "\n" .. flush_bucket_block .. "\n" .. send_ack_block
  .. "\nreturn { flush_bucket = flush_bucket, send_ack = send_ack }\n"

local ack_transmits = {}
local written_files = {}

local env = setmetatable({
  stats = {
    pending_writes = {},
    written = 0,
    ack_sent = 0,
    modems = {
      { wireless = true, modem = { transmit = function(_ch, _reply, ack) ack_transmits[#ack_transmits + 1] = ack; return true end } },
    },
  },
  fs = {
    open = function(path, mode)
      assert(mode == "a", "flush_bucket must append")
      return {
        write = function(s) written_files[path] = (written_files[path] or "") .. s end,
        close = function() end,
      }
    end,
  },
  now_ms = function() return 5000 end,
  now_s = function() return 5 end,
  computer_node_id = function() return "LOG-1" end,
  CHANNEL = 6503,
  MAX_TRACKED_NODES = 256,
  LOG_AUTH_SECRET = "test-secret",
  protocol = {
    log_auth_value = function(message) return message end,
    sign_value = function() return "signed-ack" end,
  },
}, { __index = _G })

local fn = assert(load(chunk_src, "=log_collector_flush_bucket_send_ack_test", "t", env))
local mod = fn()

-- Queue a pending write bucket exactly like write_log() would, then flush
-- it -- this is the real path that crashed on every successful write.
env.stats.pending_writes["/disk1/xreactor_logs/RT/RT-1.log"] = {
  lines = { "[log line 1]\n" },
  payloads = { { node_id = "RT-1", role = "RT", ack = true, event_id = "RT-1:42" } },
  last_flush_attempt_ms = 0,
  disk = nil,
}

local ok, err = pcall(mod.flush_bucket, "/disk1/xreactor_logs/RT/RT-1.log")
assert(ok, "flush_bucket() must not crash on a successful write -- " ..
  "the original bug: 'attempt to call global send_ack (a nil value)': " .. tostring(err))

assert(env.stats.written == 1, "a successful flush must increment stats.written")
assert(#ack_transmits == 1, "flush_bucket() must actually call the real send_ack() and transmit exactly one LOG_ACK")
assert(ack_transmits[1].event_id == "RT-1:42", "the transmitted ACK must reference the correct event_id")
assert(ack_transmits[1].status == "written", "the transmitted ACK must report status=written")
assert(ack_transmits[1].auth.mac == "signed-ack", "collector ACK must be authenticated")
assert(written_files["/disk1/xreactor_logs/RT/RT-1.log"] == "[log line 1]\n", "the buffered line must actually be written to disk")

print("log_collector_flush_bucket_send_ack_forward_decl_test.lua: ok")
