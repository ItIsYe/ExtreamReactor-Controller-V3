-- tests/installer_rt_reactor_naming_redo_test.lua
--
-- Regression test: reactor_naming.lua's ask_label() previously offered no
-- way to correct a wrongly-identified reactor other than 'Q' (aborting the
-- ENTIRE installation). Typing 'Z' at the name prompt must now discard
-- just that reactor's (uncommitted) identification and let the operator
-- redo it, keeping the SAME default label ("Reaktor N") for the retry.
-- Also asserts input() is called with the suggested default as its
-- argument (forwarded to CC:Tweaked's read()'s pre-fill parameter), so the
-- name is editable in place rather than only accept-or-retype-from-scratch.

local root = os.getenv("REPO_ROOT") or "."
local naming = assert(loadfile(root .. "/xreactor/installer/reactor_naming.lua"))()

local fake_fs = { exists = function() return false end }

local methods = {
  reactor_a = { "getActive", "getControlRodLevel", "getFuelAmount" },
  reactor_b = { "getActive", "getControlRods", "getFuelStats" },
}
local active = { reactor_a = false, reactor_b = true }
local peripheral_names = { "reactor_a", "reactor_b" }
local fake_peripheral = {
  getNames = function() return peripheral_names end,
  getMethods = function(name) return methods[name] end,
  getType = function() return "biggerreactors_reactor" end,
  call = function(name, method)
    assert(method == "getActive", "identification may only read active state")
    return active[name]
  end,
}

local reads = 0
local defaults_seen = {}
local writes = {}
local ok, state, saved = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  output = function() end,
  input = function(default)
    reads = reads + 1
    defaults_seen[reads] = default -- indexed by read count; nil defaults are common and must not shift later indices
    if reads == 1 then active.reactor_a = true; return "" end
    if reads == 2 then active.reactor_a = false; return "" end
    if reads == 3 then return "Z" end -- operator realizes the wrong reactor was toggled
    if reads == 4 then active.reactor_a = true; return "" end
    if reads == 5 then active.reactor_a = false; return "" end
    if reads == 6 then return "Ost" end
    if reads == 7 then return "West" end
    error("unexpected installer input read " .. tostring(reads))
  end,
  write = function(path, content) writes[path] = content; return true end,
})

assert(ok == true and state == "saved", "naming with a 'Z' redo must still complete and save")
assert(saved.aliases.reactor_a == "Ost" and saved.aliases.reactor_b == "West",
  "the redone reactor must end up correctly labeled")
assert(reads == 7, "expected identify+restore, 'Z', identify+restore, 2 labels = 7 reads, got " .. reads)
assert(defaults_seen[3] == "Reaktor 1" and defaults_seen[6] == "Reaktor 1",
  "a redo must keep offering the SAME default name, not advance the counter")
assert(defaults_seen[7] == "Reaktor 2",
  "the second reactor's default must resume at Reaktor 2 after the redo")
assert(active.reactor_a == false and active.reactor_b == true,
  "the original reactor state must be restored")

print("installer_rt_reactor_naming_redo_test.lua: ok")
