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
-- size at all. installer/auto_update.lua's own http_get_async() already
-- solved exactly this with an explicit os.startTimer() ceiling -- mirrored
-- here so every one of M.download()'s retry attempts is itself bounded,
-- regardless of server http.timeout config.
local function try_once(url)
  if http and type(http.request) == "function" and type(os.startTimer) == "function" then
    local ok_call, started, request_err = pcall(http.request, url)
    if not ok_call or started ~= true then
      return nil, tostring(request_err or started or "http.request failed")
    end
    local timer = os.startTimer(REQUEST_TIMEOUT_S)
    while true do
      local event, p1, p2, p3 = os.pullEvent()
      if event == "http_success" and p1 == url then
        if os.cancelTimer then pcall(os.cancelTimer, timer) end
        return read_response(p2)
      elseif event == "http_failure" and p1 == url then
        if os.cancelTimer then pcall(os.cancelTimer, timer) end
        pcall(function() if p3 then p3.close() end end)
        return nil, tostring(p2 or "http_failure")
      elseif event == "timer" and p1 == timer then
        return nil, "timeout"
      end
    end
  end

  if not http or type(http.get) ~= "function" then return nil, "no http" end
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil, "http.get failed" end
  return read_response(r)
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
