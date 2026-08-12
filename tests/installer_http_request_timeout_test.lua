-- tests/installer_http_request_timeout_test.lua
--
-- Regression test: installer/http.lua's try_once() used the plain
-- synchronous http.get(url), which has no timeout of its own -- it relies
-- entirely on the server's configured CC:Tweaked http.timeout. Reported
-- symptom: the installer sat on one file's download forever (no error, no
-- retry message, still interruptible via Ctrl+T since it's genuinely
-- waiting, not looping).
--
-- First fix attempt mirrored installer/auto_update.lua's http_get_async()
-- (http.request() + os.startTimer() + a manually filtered event loop) --
-- reported in the field to still hang well past the 15s ceiling with zero
-- retry output, despite being structurally identical to the (working)
-- code it was copied from. Rebuilt on parallel.waitForAny() instead: race
-- the proven synchronous http.get() against a plain os.sleep() timeout,
-- with no event name/id matching of our own -- CC:Tweaked's scheduler
-- decides the winner, the loser is simply abandoned.
--
-- This test simulates parallel.waitForAny() with real Lua coroutines (Lua
-- 5.2's pcall is yieldable, so this works even with try_once()'s
-- pcall(http.get, url) in the way) so both outcomes -- request wins,
-- timeout wins -- are driven exactly like CC:Tweaked's own scheduler would.

_G.parallel = {
  waitForAny = function(...)
    local fns = { ... }
    local coros = {}
    for i, fn in ipairs(fns) do coros[i] = coroutine.create(fn) end
    while true do
      for _, co in ipairs(coros) do
        if coroutine.status(co) ~= "dead" then
          local ok, err = coroutine.resume(co)
          if not ok then error(err, 0) end
          if coroutine.status(co) == "dead" then return end
        end
      end
    end
  end,
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

-- Scenario 1: the request finishes immediately (never yields) -- must win
-- the race outright, the timeout branch must never even run.
do
  _G.http = {
    get = function(url)
      return {
        readAll = function() return "return {ok=true}" end,
        close = function() end,
        getResponseCode = function() return 200 end,
      }
    end,
  }
  _G.os.sleep = function() error("timeout branch must not run when the request wins outright") end

  package.loaded["installer.http"] = nil
  local http_mod = require("installer.http")
  local body, err = http_mod.download("https://example.com/beta/xreactor/manifest.lua", { retries = 1 })
  if body ~= "return {ok=true}" then
    error("expected successful download to return the body, got body=" .. tostring(body) .. " err=" .. tostring(err))
  end
end

-- Scenario 2: the request never completes (simulates a server that never
-- responds -- http.get() yields internally, same as it would while
-- genuinely waiting on the network, and is simply never resumed again
-- once the timeout wins). download() must return a timeout error instead
-- of hanging.
do
  local get_call_started = false
  _G.http = {
    get = function(url)
      get_call_started = true
      coroutine.yield()
      error("unreachable: this coroutine must never be resumed again once the timeout wins")
    end,
  }
  _G.os.sleep = function(s)
    if s ~= 15 then error("expected the 15s request timeout, got " .. tostring(s)) end
  end

  package.loaded["installer.http"] = nil
  local http_mod = require("installer.http")
  local body, err = http_mod.download("https://example.com/beta/xreactor/manifest.lua", { retries = 1 })
  if body ~= nil then
    error("expected download() to fail when the request never completes, got body")
  end
  if not tostring(err):find("timeout", 1, true) then
    error("expected a timeout error, got: " .. tostring(err))
  end
  if not get_call_started then
    error("expected http.get() to have actually been attempted")
  end
end

print("installer_http_request_timeout_test.lua: ok")
