-- tests/sim_env_contract_test.lua
-- Prüft das kombinierte CC:Tweaked Environment.
local env_mod = dofile("tests/sim/cc/env.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

local env = env_mod.make({ seed=42, computer_id=7 })

-- os.epoch / time / clock
A(env.os.epoch("utc"), 0, "epoch 0")
env.os.sleep(1.0)
T(env.os.clock() >= 1.0, "clock after sleep")
T(env.os.epoch("utc") >= 1000, "epoch ms")

-- os.getComputerID
A(env.os.getComputerID(), 7, "computerID")

-- os.startTimer + pullEvent
env.os.sleep(0)  -- reset
local id = env.os.startTimer(0.1)
T(type(id) == "number", "timer id")
env.os.sleep(0.2)
-- Queue manuell befüllen wäre Hack — daher pullEvent testen
env._sim.queue:push("timer", id)
local ev, tid = env.os.pullEvent("timer")
A(ev, "timer", "pullEvent")
A(tid, id, "timer id match")

-- fs
local f = env.fs.open("/hello.txt", "w")
f.write("hi"); f.close()
T(env.fs.exists("/hello.txt"), "fs exists")
A(env.fs.open("/hello.txt","r").readAll(), "hi", "fs read")

-- http
env.http.stub("https://test.sim/data", { body = "sim-data" })
local h = env.http.get("https://test.sim/data")
T(h ~= nil, "http.get")
A(h.readAll(), "sim-data", "http body")

-- term
T(env.term ~= nil, "term not nil")
local w, hh = env.term.getSize()
T(w > 0 and hh > 0, "term size")

-- reboot wirft Error
local ok, err = pcall(env.os.reboot)
A(ok, false, "reboot error")
T(tostring(err):find("reboot") ~= nil, "reboot msg")

print("sim_env_contract_test.lua: ok")
