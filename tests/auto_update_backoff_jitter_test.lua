-- tests/auto_update_backoff_jitter_test.lua
--
-- Regression test: installer/auto_update.lua's M.make_loop() previously
-- retried a failed GitHub version-check at the exact same fixed cadence
-- forever, with EVERY node polling on an identical schedule -- reported in
-- the field as a contributor to GitHub rate-limiting/blocking requests
-- from the shared server IP (many nodes checking in lockstep, repeatedly,
-- with no backoff after a failure). Drives the real loop through several
-- timer cycles (same coroutine-injection technique as
-- auto_update_loop_cadence_test.lua) and asserts:
--   (a) a per-node jitter offset (derived from os.getComputerID()) shifts
--       every timer delay by a stable, node-specific amount, and
--   (b) consecutive remote-version-fetch failures double the wait each
--       time, resetting to the normal cadence as soon as a check succeeds.

local real_print = print
local timer_delays, next_timer_id, log_lines

local function reset_env(computer_id)
  timer_delays = {}
  next_timer_id = 1
  log_lines = {}
  _G.print = function(msg) log_lines[#log_lines + 1] = tostring(msg) end
  _G.os = {
    startTimer = function(delay)
      timer_delays[#timer_delays + 1] = delay
      local id = next_timer_id
      next_timer_id = next_timer_id + 1
      return id
    end,
    cancelTimer = function() end,
    pullEvent = function() return coroutine.yield() end,
    epoch = function() return 0 end,
    clock = function() return 0 end,
    sleep = function() end,
    getComputerID = computer_id and function() return computer_id end or nil,
  }
end

local function make_loop_co(interval_s)
  package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
  package.loaded["installer.auto_update"] = nil
  local auto_update = require("installer.auto_update")
  local loop_fn = auto_update.make_loop(interval_s, {})
  return coroutine.create(loop_fn)
end

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then error("loop coroutine errored: " .. tostring(err), 0) end
  if coroutine.status(co) == "dead" then
    error("loop coroutine returned/exited -- M.make_loop()'s while true must never terminate", 0)
  end
end

-- Scenario 1: jitter. Arming file missing -> fast, side-effect-free no-op
-- periodic check (same trick as auto_update_loop_cadence_test.lua) -- a
-- fixed computer ID must shift every single timer delay by id % 45.
do
  reset_env(52)
  _G.fs = { exists = function() return false end }
  _G.dofile = function(path)
    if path == "/xreactor/core/update_handshake.lua" then
      return { peek_remote_update = function() return nil end }
    end
    error("unexpected dofile: " .. tostring(path))
  end

  local co = make_loop_co(120)
  resume(co)
  resume(co, "timer", 1)
  resume(co, "timer", 2)

  local jitter = 52 % 45
  if timer_delays[1] ~= 30 + jitter then
    error("expected first delay 30+jitter=" .. (30 + jitter) .. ", got " .. tostring(timer_delays[1]))
  end
  if timer_delays[2] ~= 120 + jitter or timer_delays[3] ~= 120 + jitter then
    error("expected steady-state delay 120+jitter=" .. (120 + jitter)
      .. " on every cycle, got " .. table.concat(timer_delays, ","))
  end
end

-- Scenario 2: backoff. Auto-update armed, every GitHub fetch fails
-- (simulated network/rate-limit error) -- each periodic check must double
-- next_delay, then a single recovered fetch must reset it back to the
-- configured interval_s. No jitter here, to isolate the backoff math.
do
  reset_env(nil)
  local ARMING = "/xreactor_config/remote_update.lua"
  local failing = true
  _G.fs = {
    exists = function(path) return path == ARMING end,
    open = function(path, mode)
      if path == ARMING and mode == "r" then
        return {
          readAll = function() return "return { enabled = true, auto_update = true }" end,
          close = function() end,
        }
      end
      return nil
    end,
  }
  _G.http = {
    get = function()
      if failing then error("simulated network/rate-limit failure") end
      return {
        readAll = function() return "return { manifest_version = 1 }" end,
        close = function() end,
        getResponseCode = function() return 200 end,
      }
    end,
  }
  _G.dofile = function(path)
    if path == "/xreactor/core/update_handshake.lua" then
      return { peek_remote_update = function() return nil end }
    end
    error("unexpected dofile: " .. tostring(path))
  end

  local co = make_loop_co(100)
  resume(co)               -- initial timer: 30 (no jitter)
  resume(co, "timer", 1)   -- 1st failure -> 100*2
  resume(co, "timer", 2)   -- 2nd failure -> 100*4
  resume(co, "timer", 3)   -- 3rd failure -> 100*8

  if timer_delays[1] ~= 30 then
    error("expected initial delay 30, got " .. tostring(timer_delays[1]))
  end
  if timer_delays[2] ~= 200 or timer_delays[3] ~= 400 or timer_delays[4] ~= 800 then
    error("expected doubling backoff 200,400,800 -- got " .. table.concat(timer_delays, ","))
  end

  failing = false
  resume(co, "timer", 4)   -- recovers -> back to the normal interval_s
  if timer_delays[5] ~= 100 then
    error("expected backoff to reset to interval_s=100 after a successful check, got " .. tostring(timer_delays[5]))
  end
end

real_print("auto_update_backoff_jitter_test.lua: ok")
