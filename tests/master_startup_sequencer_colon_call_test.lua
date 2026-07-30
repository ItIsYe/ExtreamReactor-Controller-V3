-- Funktionaler Regressionstest fuer master/startup_sequencer.lua.
--
-- Bug (gefunden 2026-07-15, siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, TEST-P0-Folgearbeit zum is_master_connected-Testmuster):
-- enqueue/tick/notify_ack/notify_stable/handle_timeout waren per Punkt-
-- Syntax definiert (function self.enqueue(node_id, reason) usw.), wurden
-- aber AUSNAHMSLOS per Doppelpunkt-Syntax aufgerufen (sequencer:enqueue(...)
-- in message_handlers.lua/runtime_ops_rt.lua, sequencer:tick(...) in
-- housekeeping.lua, self:handle_timeout(...) intern in tick()). Ein
-- Doppelpunkt-Aufruf uebergibt das Objekt selbst automatisch als erstes
-- Argument -- ohne self als deklarierten Parameter landete dieses Objekt in
-- node_id/nodes/stage, wodurch enqueue() jeden echten Aufruf per Typpruefung
-- verwarf und tick()/handle_timeout() mit vertauschten/falschen Argumenten
-- liefen. Dieser Test ruft ausschliesslich per Doppelpunkt auf (wie die
-- echten Aufrufer) und prueft den kompletten Lebenszyklus.

local REPO = os.getenv("REPO_ROOT") or "."
if type(package) == "table" and type(package.path) == "string" then
  package.path = REPO .. "/xreactor/?.lua;" .. REPO .. "/xreactor/?/init.lua;" .. package.path
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local constants = require("shared.constants")
local sequencer_lib = require("master.startup_sequencer")

------------------------------------------------------------------------------
-- Happy Path: enqueue -> tick (sendet STARTUP_STAGE) -> notify_ack ->
-- notify_stable, alles ausschliesslich per Doppelpunkt-Aufruf.
------------------------------------------------------------------------------

do
  local sent = {}
  local comms = {
    send_command = function(_, node_id, payload, opts)
      table.insert(sent, { node_id = node_id, payload = payload, opts = opts })
    end,
  }
  local seq = sequencer_lib.new(comms, "NORMAL", { timeout_s = 60 })

  seq:enqueue("RT-1", "DISCOVERY")
  check(#seq.queue == 1, "enqueue() via colon-call must add the node to the queue (got " .. #seq.queue .. ")")

  local nodes = {
    ["RT-1"] = {
      id = "RT-1", mode = "MASTER", status = "OK",
      modules = { ["turbine:BigReactors-Turbine_1"] = { state = "OFF" } },
    },
  }

  seq:tick(nodes)
  check(#sent == 1, "tick() via colon-call must send the STARTUP_STAGE command (got " .. #sent .. " sends)")
  check(seq.state == "WAITING_ACK", "sequencer should be in WAITING_ACK after sending (got " .. tostring(seq.state) .. ")")
  if #sent == 1 then
    check(sent[1].node_id == "RT-1", "command must target RT-1 (got " .. tostring(sent[1].node_id) .. ")")
    check(sent[1].payload.value.module_id == "turbine:BigReactors-Turbine_1", "command must target the queued module")
  end

  seq:notify_ack("RT-1", "turbine:BigReactors-Turbine_1")
  check(seq.state == "WAITING_STABLE", "notify_ack() via colon-call must advance state to WAITING_STABLE (got " .. tostring(seq.state) .. ")")

  seq:notify_stable("RT-1", "turbine:BigReactors-Turbine_1", "RUNNING")
  check(seq.state == "IDLE", "notify_stable() via colon-call must return sequencer to IDLE (got " .. tostring(seq.state) .. ")")
  check(seq.active == nil, "notify_stable() must clear the active step")
end

------------------------------------------------------------------------------
-- handle_timeout(): called internally via self:handle_timeout(...) from
-- tick()'s WAITING_ACK branch once timeout_s has elapsed.
------------------------------------------------------------------------------

do
  local sent = {}
  local comms = {
    send_command = function(_, node_id, payload, opts)
      table.insert(sent, { node_id = node_id, payload = payload, opts = opts })
    end,
  }
  -- timeout_s = 0 so the very next tick() while WAITING_ACK immediately times out.
  local seq = sequencer_lib.new(comms, "NORMAL", { timeout_s = 0 })

  seq:enqueue("RT-1", "DISCOVERY")
  local nodes = {
    ["RT-1"] = {
      id = "RT-1", mode = "MASTER", status = "OK",
      modules = { ["turbine:X"] = { state = "OFF" } },
    },
  }
  seq:tick(nodes)
  check(seq.state == "WAITING_ACK", "must be WAITING_ACK before the timeout tick")
  check(#sent == 1, "one STARTUP_STAGE command expected before timeout")

  seq:tick(nodes)
  check(seq.state == "IDLE", "handle_timeout() via internal colon-call must reset sequencer to IDLE (got " .. tostring(seq.state) .. ")")
  check(seq.active == nil, "handle_timeout() must clear the active step")
  check(#sent == 2, "handle_timeout() must send a MODE command for the timed-out node (got " .. #sent .. " sends)")
  if #sent == 2 then
    check(sent[2].node_id == "RT-1", "timeout MODE command must target the correct node (got " .. tostring(sent[2].node_id) .. ")")
    check(sent[2].payload.target == constants.command_targets.MODE, "timeout must send a MODE command")
  end
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
