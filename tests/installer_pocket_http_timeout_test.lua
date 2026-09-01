-- tests/installer_pocket_http_timeout_test.lua
--
-- Regression test: /installer_pocket's download loop used plain
-- pcall(http.get, url) with no timeout of its own, the same field-
-- reported hang pattern documented in installer_http_request_timeout_test.lua
-- and fixed across installer/http.lua, installer/auto_update.lua, and the
-- top-level /installer bootstrap. try_once() here now races the proven
-- synchronous http.get() against a plain os.sleep() timeout via
-- parallel.waitForAny(), identical to those fixes.
--
-- Extracts just try_once() via marker extraction (the file has real
-- top-level side effects -- error()s without http, writes /startup.lua on
-- success -- so it can't be required/dofile()d directly in a test) and
-- drives both race outcomes with real Lua coroutines, same methodology as
-- installer_http_request_timeout_test.lua and
-- auto_update_http_get_async_timeout_test.lua.

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
local source = read_file(root .. "/installer_pocket")
local helpers = extract(source, "local REQUEST_TIMEOUT_S = 15", "local content, last_err")

local function load_helpers()
  local chunk = assert(load(helpers .. [[
return { try_once = try_once }
]], "=installer_pocket_helpers", "t", _ENV))
  return chunk()
end

-- Scenario 1: the request finishes immediately -- must win the race
-- outright, the timeout branch must never even run.
do
  _G.http = {
    get = function(url)
      return {
        readAll = function() return "print('pocket client')" end,
        close = function() end,
      }
    end,
  }
  _G.os = { sleep = function() error("timeout branch must not run when the request wins outright") end }

  local mod = load_helpers()
  local body, err = mod.try_once("https://example.com/beta/xreactor/optional/pocket_client.lua")
  if body ~= "print('pocket client')" then
    error("expected successful fetch to return the body, got body=" .. tostring(body) .. " err=" .. tostring(err))
  end
end

-- Scenario 2: the request never completes -- must return a timeout error
-- instead of hanging forever.
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
  local body, err = mod.try_once("https://example.com/beta/xreactor/optional/pocket_client.lua")
  if body ~= nil then
    error("expected try_once() to fail when the request never completes, got body")
  end
  if not tostring(err):find("timeout", 1, true) then
    error("expected a timeout error, got: " .. tostring(err))
  end
  if not get_call_started then
    error("expected http.get() to have actually been attempted")
  end
end

print("installer_pocket_http_timeout_test.lua: ok")
