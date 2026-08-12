local root = os.getenv("REPO_ROOT") or "."
local naming = assert(loadfile(root .. "/xreactor/installer/reactor_naming.lua"))()

local files = {}
local fake_fs = {
  exists = function(path) return files[path] ~= nil end,
  open = function(path, mode)
    if mode ~= "r" or files[path] == nil then return nil end
    return {
      readAll = function() return files[path] end,
      close = function() end,
    }
  end,
}

local methods = {
  reactor_a = { "getActive", "getControlRodLevel", "getFuelAmount" },
  reactor_b = { "getActive", "getControlRods", "getFuelStats" },
  turbine_a = { "getRotorSpeed", "setFluidFlowRate" },
}
local active = { reactor_a = false, reactor_b = true }
local peripheral_calls = {}
local peripheral_names = { "turbine_a", "reactor_b", "reactor_a" }
local fake_peripheral = {
  getNames = function() return peripheral_names end,
  getMethods = function(name) return methods[name] end,
  getType = function(name)
    if name == "turbine_a" then return "biggerreactors_turbine" end
    return "biggerreactors_reactor"
  end,
  call = function(name, method)
    peripheral_calls[#peripheral_calls + 1] = { name = name, method = method }
    assert(method == "getActive", "live identification may only read active state")
    return active[name]
  end,
}

local detected = naming.detect(fake_peripheral)
assert(#detected == 2 and detected[1] == "reactor_a" and detected[2] == "reactor_b",
  "only reactors must be detected in stable order")

local reads, outputs = 0, {}
local ok, state, saved = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  output = function(message) outputs[#outputs + 1] = message end,
  input = function()
    reads = reads + 1
    if reads == 1 then active.reactor_a = true; return "" end
    if reads == 2 then active.reactor_a = false; return "" end
    if reads == 3 then return "Nord" end
    if reads == 4 then return "Nord" end
    if reads == 5 then return "Sued" end
    error("unexpected installer input read " .. tostring(reads))
  end,
  write = function(path, content) files[path] = content; return true end,
})
assert(ok == true and state == "saved", "fresh RT naming must be persisted")
assert(reads == 5, "identification, restoration and duplicate label must be confirmed")
assert(saved.aliases.reactor_a == "Nord" and saved.aliases.reactor_b == "Sued",
  "display names must stay attached to peripheral identities")
assert(active.reactor_a == false and active.reactor_b == true,
  "the original reactor state must be restored")
for _, call in ipairs(peripheral_calls) do
  assert(call.method ~= "setActive", "installer must never switch reactor state itself")
end
assert(table.concat(outputs, "\n"):find("Erkannt: reactor_a", 1, true),
  "operator must see which peripheral changed")

local loaded = naming.load(fake_fs)
assert(loaded and loaded.completed and loaded.aliases.reactor_a == "Nord",
  "saved naming config must round-trip")

local second_reads = 0
local ok_second, second_state = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  input = function() second_reads = second_reads + 1; return "unexpected" end,
  write = function() error("completed naming must not be rewritten") end,
})
assert(ok_second and second_state == "already_completed" and second_reads == 0,
  "completed naming must never prompt again")

methods.reactor_c = { "getActive", "getFuelAmount" }
active.reactor_c = false
peripheral_names = { "reactor_a", "reactor_b", "reactor_c" }
local changed_reads = 0
local ok_changed, changed_state, changed_info = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  input = function() changed_reads = changed_reads + 1; return "unexpected" end,
  write = function() error("topology warning must not rewrite naming") end,
})
assert(ok_changed and changed_state == "already_completed_topology_changed")
assert(changed_info.topology_changed and changed_reads == 0,
  "changed topology must not reopen the completed dialog")

peripheral_names = { "reactor_a", "reactor_b" }
files[naming.CONFIG_PATH] = nil
local remote_reads = 0
local ok_remote, remote_state = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  remote_update = true,
  input = function() remote_reads = remote_reads + 1; return "unexpected" end,
  write = function() error("remote update must not create naming config") end,
})
assert(ok_remote and remote_state == "remote_update_skipped" and remote_reads == 0,
  "unattended update must never enter naming")

local abort_ok, abort_state = naming.run({
  fs = fake_fs, peripheral = fake_peripheral, output = function() end,
  input = function() return "Q" end,
  write = function() error("aborted naming must not persist") end,
})
assert(abort_ok == false and abort_state == "operator_aborted")

files[naming.CONFIG_PATH] = "return { completed=true, aliases={a='Nord',b='nord'}, reactors={'a','b'} }"
local corrupt_reads = 0
local corrupt_ok, corrupt_state = naming.run({
  fs = fake_fs, peripheral = fake_peripheral,
  input = function() corrupt_reads = corrupt_reads + 1; return "unexpected" end,
  write = function() error("invalid completed config must not be overwritten") end,
})
assert(corrupt_ok == false and corrupt_state == "invalid_existing_config:duplicate_label"
  and corrupt_reads == 0, "invalid persisted naming must fail closed without prompting")

files[naming.CONFIG_PATH] = nil
active.reactor_a, active.reactor_b = false, true
local failure_reads = 0
local restore_ok, restore_state = naming.run({
  fs = fake_fs, peripheral = fake_peripheral, output = function() end,
  input = function()
    failure_reads = failure_reads + 1
    if failure_reads == 1 then active.reactor_a = true
    elseif failure_reads == 2 then active.reactor_a = nil end
    return ""
  end,
  write = function() error("unreadable restore state must not persist") end,
})
assert(restore_ok == false and restore_state == "reactor_restore_timeout")
assert(failure_reads <= naming.MAX_RESTORE_ATTEMPTS + 1, "restore failure must be bounded")

print("installer_rt_reactor_naming_test.lua: ok")
