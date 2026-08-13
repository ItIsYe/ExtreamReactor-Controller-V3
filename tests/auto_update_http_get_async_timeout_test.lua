-- tests/auto_update_http_get_async_timeout_test.lua
--
-- Regression test: installer/auto_update.lua's http_get_async() used
-- http.request()+os.startTimer()+a manually filtered event loop --
-- documented in installer/http.lua's own history (see
-- installer_http_request_timeout_test.lua) as reported in the field to
-- hang well past its 15s ceiling with zero retry output, the exact
-- pattern installer/http.lua's try_once() was rebuilt away from. Since
-- auto_update.lua is deliberately self-contained, that fix was never
-- mirrored here, leaving fetch_remote_version() (the periodic update-
-- availability check, called every check_interval_s) vulnerable to
-- silently hanging forever on a request that never fires an http_success/
-- http_failure event.
--
-- http_get_async() now uses the same proven parallel.waitForAny() race
-- (synchronous http.get() vs. a plain os.sleep() timeout) as
-- installer/http.lua's try_once(). This test extracts just http_get_async()
-- and its two small dependencies (close_response/read_response) via marker
-- extraction -- same approach as auto_update_ensure_temp_space_test.lua --
-- and drives both race outcomes with real Lua coroutines, mirroring
-- installer_http_request_timeout_test.lua's methodology exactly.

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

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function extract(source, first_marker, last_marker)
  local first = assert(source:find(first_marker, 1, true))
  local last = assert(source:find(last_marker, first, true))
  return source:sub(first, last - 1)
end

local root = os.getenv("REPO_ROOT") or "."
local source = read_file(root .. "/xreactor/installer/auto_update.lua")
local helpers = extract(source, "local function close_response(response)", "local function load_arming()")

local function load_helpers()
  local chunk = assert(load(helpers .. [[
return { http_get_async = http_get_async }
]], "=auto_update_http_helpers", "t", _ENV))
  return chunk()
end

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
  _G.os = { sleep = function() error("timeout branch must not run when the request wins outright") end }

  local mod = load_helpers()
  local body, err = mod.http_get_async("https://example.com/beta/xreactor/release.lua")
  if body ~= "return {ok=true}" then
    error("expected successful fetch to return the body, got body=" .. tostring(body) .. " err=" .. tostring(err))
  end
end

-- Scenario 2: the request never completes (simulates a server that never
-- responds, or an http_success/http_failure event that never fires -- the
-- exact field-reported failure mode of the old http.request()-based
-- implementation). http_get_async() must return a timeout error instead
-- of hanging forever.
do
  local get_call_started = false
  _G.http = {
    get = function(url)
      get_call_started = true
      coroutine.yield()
      error("unreachable: this coroutine must never be resumed again once the timeout wins")
    end,
  }
  _G.os = {
    sleep = function(s)
      if s ~= 15 then error("expected the 15s request timeout, got " .. tostring(s)) end
    end,
  }

  local mod = load_helpers()
  local body, err = mod.http_get_async("https://example.com/beta/xreactor/release.lua")
  if body ~= nil then
    error("expected http_get_async() to fail when the request never completes, got body")
  end
  if not tostring(err):find("timeout", 1, true) then
    error("expected a timeout error, got: " .. tostring(err))
  end
  if not get_call_started then
    error("expected http.get() to have actually been attempted")
  end
end

print("auto_update_http_get_async_timeout_test.lua: ok")
