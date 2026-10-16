-- Regression test (2026-09-17, "sieht aus wie Kommunikationsprobleme,
-- alle offline"): build_steps() used to expand the ENTIRE queue into
-- module-level steps in one single, non-yielding pass -- calling
-- plan_modules() (pairs() iteration + table.sort()) for every queued node
-- back to back. When many RT nodes enqueued near-simultaneously (the
-- whole fleet starting up at once), this single call could run long
-- enough to trip CC:Tweaked's "Too long without yielding" watchdog --
-- confirmed by the actual crash log: "Service tick failed (HOUSEKEEPING)
-- ...: /xreactor/master/startup_sequ:19/29: Too long without yielding",
-- pointing exactly at plan_modules()'s pairs() loop and table.sort() call.
-- While that MASTER tick was blocked/retried, it also stopped sending its
-- own heartbeats, so every peer correctly (but misleadingly) reported it
-- as "offline" -- not an actual network problem.
--
-- Fix: build_steps() now expands only the FRONT queue entry per call,
-- leaving the rest of the queue as unexpanded node-only placeholders.
-- tick() already re-invokes build_steps() on every IDLE tick as long as
-- queue[1] lacks a module_id, so the expansion cost spreads across as
-- many ticks as there are queued nodes instead of happening all at once.

local REPO = os.getenv("REPO_ROOT") or "."
if type(package) == "table" and type(package.path) == "string" then
  package.path = REPO .. "/xreactor/?.lua;" .. REPO .. "/xreactor/?/init.lua;" .. package.path
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local sequencer_lib = require("master.startup_sequencer")

local comms = { send_command = function() end }
local seq = sequencer_lib.new(comms, "NORMAL", { timeout_s = 60 })

seq:enqueue("RT-1", "DISCOVERY")
seq:enqueue("RT-2", "DISCOVERY")
seq:enqueue("RT-3", "DISCOVERY")
check(#seq.queue == 3, "expected 3 unexpanded node placeholders queued (got " .. #seq.queue .. ")")

local nodes = {
  ["RT-1"] = { id = "RT-1", mode = "MASTER", status = "OK",
    modules = { ["turbine:A"] = { state = "OFF" }, ["reactor:A"] = { state = "OFF" } } },
  ["RT-2"] = { id = "RT-2", mode = "MASTER", status = "OK",
    modules = { ["turbine:B"] = { state = "OFF" } } },
  ["RT-3"] = { id = "RT-3", mode = "MASTER", status = "OK",
    modules = { ["turbine:C"] = { state = "OFF" } } },
}

-- A single build_steps() call must expand ONLY the front entry (RT-1,
-- 2 modules) into module-level steps, leaving RT-2/RT-3 untouched as
-- bare node placeholders (no module_id yet).
seq.build_steps(nodes)
check(#seq.queue == 4, "expected RT-1 expanded into 2 module steps + 2 untouched placeholders (got " .. #seq.queue .. ")")
check(seq.queue[1].module_id == "turbine:A", "front entry after first build_steps() must be RT-1's turbine (got " .. tostring(seq.queue[1].module_id) .. ")")
check(seq.queue[2].module_id == "reactor:A", "second entry must be RT-1's reactor (got " .. tostring(seq.queue[2].module_id) .. ")")
check(seq.queue[3].node_id == "RT-2" and seq.queue[3].module_id == nil,
  "RT-2 must remain an unexpanded placeholder after RT-1's build_steps() call")
check(seq.queue[4].node_id == "RT-3" and seq.queue[4].module_id == nil,
  "RT-3 must remain an unexpanded placeholder after RT-1's build_steps() call")

-- Draining RT-1's two steps via tick()/notify_ack/notify_stable, then the
-- next IDLE tick's build_steps() call must expand only RT-2 next -- RT-3
-- still untouched.
local sent = {}
comms.send_command = function(_, node_id, payload) table.insert(sent, { node_id = node_id, payload = payload }) end
seq:tick(nodes)
check(#sent == 1 and sent[1].node_id == "RT-1", "tick() must start with RT-1's front-most module step")
seq:notify_ack("RT-1", sent[1].payload.value.module_id)
seq:notify_stable("RT-1", sent[1].payload.value.module_id, "RUNNING")
seq:tick(nodes)
check(#sent == 2 and sent[2].node_id == "RT-1", "second step must still be RT-1 (its other module)")
seq:notify_ack("RT-1", sent[2].payload.value.module_id)
seq:notify_stable("RT-1", sent[2].payload.value.module_id, "RUNNING")

check(seq.queue[1].node_id == "RT-2" and seq.queue[1].module_id == nil,
  "after RT-1 fully drains, RT-2 must be the new front placeholder, still unexpanded")
check(seq.queue[2].node_id == "RT-3" and seq.queue[2].module_id == nil,
  "RT-3 must still be untouched (not expanded by RT-1's or RT-2's build_steps() calls)")

if fail == 0 then
  print("master_startup_sequencer_incremental_build_steps_test.lua: ok")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
