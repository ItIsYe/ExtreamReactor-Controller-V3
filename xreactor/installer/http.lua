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
    -- Muss denselben Erfolgsbereich wie auto_update.lua akzeptieren
    -- (200-299), nicht nur exakt 200 -- sonst behandeln beide Module
    -- denselben Server anders und ein 2xx-Code ausserhalb von genau 200
    -- (z.B. 204/206) liesse hier den Download unnoetig fehlschlagen.
    if ok_code and type(code) == "number" and (code < 200 or code >= 300) then
      pcall(response.close)
      return nil, "HTTP " .. tostring(code)
    end
  end
  local ok, body = pcall(response.readAll)
  pcall(response.close)
  if not ok or type(body) ~= "string" then return nil, "read failed" end
  return body
end

-- Plain http.get(url) has no timeout of its own -- relies entirely on the
-- server's http.timeout config, so a stuck request could hang forever.
-- Races the proven synchronous http.get() against a plain os.sleep()
-- timeout via parallel.waitForAny() -- returns as soon as either coroutine
-- finishes, no event name/id matching of our own (a manual http.request()+
-- os.startTimer() event loop was tried first and hung unreliably in the
-- field despite working elsewhere). If http.get() never yields, the
-- sleep-timer coroutine still lets waitForAny return; the abandoned
-- http.get() coroutine is simply dropped.
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
