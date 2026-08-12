-- tests/installer_http_request_timeout_test.lua
--
-- Regression test: installer/http.lua's try_once() used the plain
-- synchronous http.get(url), which has no timeout of its own -- it relies
-- entirely on the server's configured CC:Tweaked http.timeout. Reported
-- symptom: the installer sat on one file's download forever (no error, no
-- retry message, still interruptible via Ctrl+T since it's genuinely
-- waiting on an event, not looping) -- unrelated to that file's size,
-- since smaller files downloaded fine both before and after it.
--
-- installer/auto_update.lua's own http_get_async() already solved this
-- with an explicit os.startTimer() ceiling. This test drives
-- installer/http.lua's download() through a simulated CC:Tweaked event
-- loop where http.request() "succeeds" (returns true, queuing a request)
-- but NEITHER http_success NOR http_failure ever arrives -- only the
-- timer fires. download() must return a timeout error instead of hanging;
-- if the fix regresses back to plain http.get()-only behavior with no
-- request/startTimer usage, this test would otherwise spin the mocked
-- event loop forever, so pullEvent has a hard call-count guard that turns
-- that into a clear failure instead of hanging the test runner.

local requested_urls = {}
local timers_started = {}
local pull_calls = 0
local PULL_CALL_GUARD = 200

_G.http = {
  request = function(url)
    requested_urls[#requested_urls + 1] = url
    return true
  end,
}

_G.os = {
  epoch = function() return 0 end,
  sleep = function() end,
  time = os.time,
  startTimer = function(delay)
    local id = #timers_started + 1
    timers_started[#timers_started + 1] = delay
    return id
  end,
  cancelTimer = function() end,
  pullEvent = function()
    pull_calls = pull_calls + 1
    if pull_calls > PULL_CALL_GUARD then
      error("try_once() never timed out -- simulated event loop spun " .. PULL_CALL_GUARD .. "+ times without a 'timer' event being accepted")
    end
    -- Only the timer for the most recently started timer ever fires --
    -- http_success/http_failure never arrive for this URL, simulating a
    -- request that never gets a response.
    return "timer", #timers_started
  end,
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
local http_mod = require("installer.http")

local body, err = http_mod.download("https://raw.githubusercontent.com/example/x/beta/xreactor/manifest.lua",
  { retries = 1 })

if body ~= nil then
  error("expected download() to fail when no http_success/http_failure ever arrives, got body")
end
if not tostring(err):find("timeout", 1, true) then
  error("expected a timeout error, got: " .. tostring(err))
end
if #requested_urls == 0 then
  error("expected try_once() to use http.request(), not fall back straight to http.get()")
end
if #timers_started == 0 then
  error("expected try_once() to start an explicit timeout timer via os.startTimer()")
end

print("installer_http_request_timeout_test.lua: ok")
