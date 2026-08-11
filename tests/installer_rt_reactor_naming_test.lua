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
local fake_peripheral = {
  getNames = function() return { "turbine_a", "reactor_b", "reactor_a" } end,
  getMethods = function(name) return methods[name] end,
  getType = function(name)
    if name == "turbine_a" then return "biggerreactors_turbine" end
    return "biggerreactors_reactor"
  end,
  call = function(name, method)
    peripheral_calls[#peripheral_calls + 1] = { name = name, method = method }
    assert(method == "getActive", "live identification must only read the active state")
    return active[name]
  end,
}

local detected = naming.detect(fake_peripheral)
assert(#detected == 2 and detected[1] == "reactor_a" and detected[2] == "reactor_b",
  "only reactors must be detected in stable order")

local reads = 0
local outputs = {}
local ok, state, saved = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  output = function(message) outputs[#outputs + 1] = message end,
  input = function()
    reads = reads + 1
    if reads == 1 then active.reactor_a = true; return "" end -- operator toggles one reactor
    if reads == 2 then active.reactor_a = false; return "" end -- operator restores original state
    if reads == 3 then return "Nord" end
    if reads == 4 then return "Nord" end -- duplicate label for the final reactor
    if reads == 5 then return "Sued" end
    error("unexpected installer input read " .. tostring(reads))
  end,
  write = function(path, content) files[path] = content; return true end,
})
assert(ok == true and state == "saved", "fresh RT naming must be persisted")
assert(reads == 5, "live identification, restoration and duplicate labels must all be confirmed")
assert(saved.aliases.reactor_a == "Nord" and saved.aliases.reactor_b == "Sued",
  "entered display names must stay attached to peripheral identities")
assert(active.reactor_a == false and active.reactor_b == true,
  "live identification must require the original reactor state to be restored")
for _, call in ipairs(peripheral_calls) do
  assert(call.method ~= "setActive", "installer must never switch reactor state itself")
end
assert(table.concat(outputs, "\n"):find("Erkannt: reactor_a", 1, true),
  "operator must be told which technical peripheral changed")

local loaded = naming.load(fake_fs)
assert(loaded and loaded.completed == true, "saved completion marker must load")
assert(loaded.aliases.reactor_a == "Nord" and loaded.aliases.reactor_b == "Sued",
  "saved aliases must round-trip")

local second_reads = 0
local ok_second, second_state = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  output = function() end,
  input = function() second_reads = second_reads + 1; return "unexpected" end,
  write = function() error("completed naming must not be rewritten") end,
})
assert(ok_second == true and second_state == "already_completed",
  "completed naming must be skipped on later installations")
assert(second_reads == 0, "completed naming must never prompt again")

files[naming.CONFIG_PATH] = nil
local remote_reads = 0
local ok_remote, remote_state = naming.run({
  fs = fake_fs,
  peripheral = fake_peripheral,
  remote_update = true,
  input = function() remote_reads = remote_reads + 1; return "unexpected" end,
  write = function() error("remote update must not create interactive naming config") end,
})
assert(ok_remote == true and remote_state == "remote_update_skipped" and remote_reads == 0,
  "unattended updates must never enter the naming prompt")

print("installer_rt_reactor_naming_test.lua: ok")
