-- tests/start_recovery_resume_timeout_test.lua
--
-- Regression test: xreactor/start.lua's attempt_recovery_resume() (the boot-
-- time recovery path taken when the install journal shows an incomplete or
-- corrupt installation) used plain pcall(http.get, url) with no timeout of
-- its own and no retry loop -- a fifth independent copy of the same field-
-- reported hang pattern already fixed in installer/http.lua,
-- installer/auto_update.lua, the top-level /installer bootstrap, and
-- /installer_pocket. Since this path runs on every boot after any
-- interrupted install (before any other module is loaded), a stalled
-- request here hung the entire boot forever, with no way to self-recover.
--
-- recovery_try_once() now races the proven synchronous http.get() against a
-- plain os.sleep() timeout via parallel.waitForAny(), identical to the
-- other fixes, and attempt_recovery_resume() retries it up to 4 times with
-- backoff. Extracts just recovery_try_once() via marker extraction (the
-- file has real top-level side effects) and drives both race outcomes with
-- real Lua coroutines, same methodology as
-- installer_bootstrap_try_once_timeout_test.lua.

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
local source = read_file(root .. "/xreactor/start.lua")
local helpers = extract(source, "local RECOVERY_REQUEST_TIMEOUT_S = 15", "local function attempt_recovery_resume()")

local function load_helpers()
  local chunk = assert(load(helpers .. [[
return { recovery_try_once = recovery_try_once }
]], "=start_recovery_helpers", "t", _ENV))
  return chunk()
end

-- Scenario 1: the request finishes immediately -- must win the race
-- outright, the timeout branch must never even run.
do
  _G.http = {
    get = function(url)
      return {
        readAll = function() return "-- installer body" end,
        close = function() end,
      }
    end,
  }
  _G.os = { sleep = function() error("timeout branch must not run when the request wins outright") end }

  local mod = load_helpers()
  local body, err = mod.recovery_try_once("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer")
  if body ~= "-- installer body" then
    error("expected successful fetch to return the body, got body=" .. tostring(body) .. " err=" .. tostring(err))
  end
end

-- Scenario 2: the request never completes -- must return a timeout error
-- instead of hanging the boot forever (the actual field-reported symptom
-- class: recovery-resume stuck here with no other module ever loaded).
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
  local body, err = mod.recovery_try_once("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer")
  if body ~= nil then
    error("expected recovery_try_once() to fail when the request never completes, got body")
  end
  if not tostring(err):find("timeout", 1, true) then
    error("expected a timeout error, got: " .. tostring(err))
  end
  if not get_call_started then
    error("expected http.get() to have actually been attempted")
  end
end

print("start_recovery_resume_timeout_test.lua: ok")
