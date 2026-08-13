-- tests/auto_update_loop_cadence_test.lua
--
-- Regression test: installer/auto_update.lua's M.make_loop() is only ever
-- covered by static text-presence checks elsewhere (e.g.
-- install_p0_2_quiesce_wiring_test.lua just greps for
-- "function M.make_loop(interval_s, handshake)") -- nothing actually
-- drives the loop through real timer cycles to prove the documented
-- cadence (first periodic check ~30s after start, then every
-- interval_s afterward) actually fires do_periodic_check() on every
-- single cycle, never stalling or skipping.
--
-- Drives the real loop function (loaded via require, not marker
-- extraction -- the whole module has no load-time side effects) inside a
-- coroutine, injecting "timer" events exactly like CC:Tweaked's own
-- scheduler would via coroutine.resume(co, "timer", id), and observes:
-- (a) every os.startTimer() delay requested, in order, and
-- (b) how many times do_periodic_check() actually ran, via its
--     "Auto-Update uebersprungen" log line (fs.exists() is mocked to
--     always report the arming file missing, so each periodic check is a
--     fast, side-effect-free no-op that still proves the loop reached it).

local real_print = print
local log_lines = {}
_G.print = function(msg) log_lines[#log_lines + 1] = tostring(msg) end

local timer_delays = {}
local next_timer_id = 1

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
}

_G.fs = {
  -- ARMING_PATH never exists -> load_arming() returns "not armed" ->
  -- do_periodic_check() logs and returns immediately, no HTTP involved.
  exists = function() return false end,
}

_G.dofile = function(path)
  if path == "/xreactor/core/update_handshake.lua" then
    return { peek_remote_update = function() return nil end }
  end
  error("unexpected dofile: " .. tostring(path))
end

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
package.loaded["installer.auto_update"] = nil
local auto_update = require("installer.auto_update")

local handshake = {}
local loop_fn = auto_update.make_loop(120, handshake)
local co = coroutine.create(loop_fn)

local function resume(...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then error("loop coroutine errored: " .. tostring(err), 0) end
  if coroutine.status(co) == "dead" then
    error("loop coroutine returned/exited -- M.make_loop()'s while true must never terminate", 0)
  end
end

-- Initial resume: runs "Loop gestartet", do_remote_request() (no-op, no
-- yield), the first os.startTimer(30), then blocks inside os.pullEvent().
resume()

-- Drive 4 full timer cycles: each injected "timer" event should make the
-- loop run do_periodic_check() once, then loop back and arm the NEXT
-- timer with the configured interval_s (120s), then block again.
for i = 1, 4 do
  resume("timer", i)
end

if #timer_delays ~= 5 then
  error("expected 5 os.startTimer() calls (1 initial + 4 cycles), got " .. #timer_delays
    .. " (" .. table.concat(timer_delays, ",") .. ")")
end
if timer_delays[1] ~= 30 then
  error("expected the first timer delay to be 30s, got " .. tostring(timer_delays[1]))
end
for i = 2, 5 do
  if timer_delays[i] ~= 120 then
    error("expected timer delay #" .. i .. " to be the configured interval_s=120, got " .. tostring(timer_delays[i]))
  end
end

local skip_count = 0
for _, line in ipairs(log_lines) do
  if line:find("Auto-Update uebersprungen", 1, true) then skip_count = skip_count + 1 end
end
if skip_count ~= 4 then
  error("expected do_periodic_check() to have run on every one of the 4 timer firings, got "
    .. skip_count .. " (log_lines=" .. table.concat(log_lines, " | ") .. ")")
end

-- An UPDATE_EVENT while waiting on the periodic timer must not disturb the
-- still-pending timer's own cycle -- it re-checks for a queued remote
-- update and keeps waiting for the SAME timer id, no new timer started.
resume("xreactor_remote_update_requested")
if #timer_delays ~= 5 then
  error("an UPDATE_EVENT must not itself start a new timer while one is already pending, got "
    .. #timer_delays .. " timers")
end

-- The still-pending timer (id=5, the last one armed above) must still
-- fire normally afterward.
resume("timer", next_timer_id - 1)
if #timer_delays ~= 6 then
  error("expected the still-pending timer to fire and arm one more (6th) timer, got "
    .. #timer_delays .. " timers")
end
skip_count = 0
for _, line in ipairs(log_lines) do
  if line:find("Auto-Update uebersprungen", 1, true) then skip_count = skip_count + 1 end
end
if skip_count ~= 5 then
  error("expected do_periodic_check() to have run a 5th time after the UPDATE_EVENT interruption, got "
    .. skip_count)
end

real_print("auto_update_loop_cadence_test.lua: ok")
