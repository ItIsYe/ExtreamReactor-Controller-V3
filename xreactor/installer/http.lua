-- installer/http.lua
-- Download-Modul: ein vom Aufrufer gewaehlter Ref, Retries, HTML-Check

local M = {}

local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"
local REQUEST_TIMEOUT_S = 15

-- HTML-Erkennung (CDN-Fehlerseiten)
function M.is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

local function read_response(response)
  if not response then return nil, "empty response" end
  if type(response.getResponseCode) == "function" then
    local ok_code, code = pcall(response.getResponseCode)
    if ok_code and type(code) == "number" and code ~= 200 then
      pcall(response.close)
      return nil, "HTTP " .. tostring(code)
    end
  end
  local ok, body = pcall(response.readAll)
  pcall(response.close)
  if not ok or type(body) ~= "string" then return nil, "read failed" end
  return body
end

-- Fix: this used the plain synchronous http.get(url), which has NO
-- explicit timeout of its own -- it relies entirely on the server's
-- configured CC:Tweaked http.timeout. If that's disabled/very high (or a
-- single request just never gets a response), the installer could sit on
-- one file forever: no crash, no retry message, still interruptible via
-- Ctrl+T (it's genuinely waiting, not looping) since it's not tied to file
-- size at all.
--
-- First attempt mirrored installer/auto_update.lua's http_get_async()
-- (http.request() + os.startTimer() + a manually filtered event loop
-- matching http_success/http_failure/timer by url/timer id). Reported in
-- the field: still hung well past the 15s ceiling with zero retry output
-- -- the manual event matching has more moving parts (event names, timer
-- id equality, url equality against a cache-busted query string) than it
-- needs, and something in that chain wasn't firing reliably even though
-- the structurally identical code in auto_update.lua worked for smaller,
-- unbusted single-file requests.
--
-- Rebuilt on parallel.waitForAny() instead: race the already-proven
-- synchronous http.get() against a plain os.sleep() timeout. CC:Tweaked's
-- parallel.* returns as soon as either coroutine finishes -- no event name
-- or id matching of our own, no dependency on http.request()'s specific
-- success/failure event semantics. If http.get() itself never yields at
-- all (shouldn't happen -- it's fully synchronous sugar over the same
-- event wait), the sleep-timer coroutine still lets waitForAny return, and
-- the abandoned http.get() coroutine is simply dropped.
local function try_once(url)
  if not http or type(http.get) ~= "function" then return nil, "no http" end
  if type(parallel) ~= "table" or type(parallel.waitForAny) ~= "function" then
    local ok, r = pcall(http.get, url)
    if not ok or not r then return nil, "http.get failed" end
    return read_response(r)
  end

  local body, err, done = nil, nil, false
  local ok_race, race_err = pcall(parallel.waitForAny,
    function()
      local ok, r = pcall(http.get, url)
      if ok and r then
        body, err = read_response(r)
      else
        err = "http.get failed"
      end
      done = true
    end,
    function() os.sleep(REQUEST_TIMEOUT_S) end)

  if not ok_race then return nil, "request failed: " .. tostring(race_err) end
  if not done then return nil, "timeout" end
  return body, err
end

-- Download mit Retries und Cache-Busting.
-- opts: { retries=4, delays={2,5,10,20} }
function M.download(url, opts)
  opts = opts or {}
  local retries = opts.retries or 4
  local delays  = opts.delays  or {2, 5, 10, 20}
  local last_err
  for attempt = 1, retries do
    -- Cache-Bust
    local sep = url:find("?", 1, true) and "&" or "?"
    local t   = tostring(os.epoch and os.epoch("utc") or os.time())
    local u   = url .. sep .. "xr_cb=" .. attempt .. "_" .. t
    local body, err = try_once(u)
    if body then
      if M.is_html(body) then
        last_err = "unexpected HTML (CDN error)"
      else
        return body, url
      end
    else
      last_err = err
    end
    if attempt < retries then
      os.sleep(delays[attempt] or 20)
    end
  end
  return nil, tostring(last_err or "download failed after " .. retries .. " retries")
end

-- Verwendet ausschliesslich den vom Bootstrap gewaehlten Ref. Ein einzelner
-- Dateidownload darf nie still auf einen anderen Branch oder Commit fallen.
function M.download_file(rel_path, ref, opts)
  local url
  if ref and ref ~= "beta" then
    url = GITHUB_RAW .. ref .. "/xreactor/" .. rel_path
  else
    url = GITHUB_RAW .. "beta/xreactor/" .. rel_path
  end
  local body, err = M.download(url, opts)
  if body then return body, url end
  return nil, "Download fehlgeschlagen fuer " .. rel_path .. ": " .. tostring(err)
end

return M
