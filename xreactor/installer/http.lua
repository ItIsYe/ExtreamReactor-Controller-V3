-- installer/http.lua
-- Download-Modul: SHA-PIN, Retries, HTML-Check, Timeout

local M = {}

local GITHUB_API  = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local GITHUB_RAW  = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

function M.resolve_sha(timeout_s)
  if not http or type(http.get) ~= "function" then return nil end
  timeout_s = timeout_s or 10
  for attempt = 1, 3 do
    local ok, r = pcall(http.get, GITHUB_API, nil, { timeout = timeout_s })
    if ok and r then
      local ok2, body = pcall(r.readAll); pcall(r.close)
      if ok2 and type(body) == "string" then
        local sha = body:match('"sha"%s*:%s*"(%x+)"')
        if sha then return sha end
      end
    end
    if attempt < 3 then os.sleep(3) end
  end
  return nil
end

function M.is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

function M.download(url, opts)
  opts = opts or {}
  local retries   = opts.retries  or 4
  local delays    = opts.delays   or {2, 5, 10, 20}
  local timeout_s = opts.timeout  or 20
  if not http then return nil, "HTTP API unavailable" end

  local use_async = type(http.request) == "function"
    and type(os.startTimer) == "function"
    and type(os.pullEvent) == "function"

  local function try_async(u)
    local ok_req = pcall(http.request, u)
    if not ok_req then return nil, "request failed" end
    local timer = os.startTimer(timeout_s)
    while true do
      local ev, p1, p2, p3 = os.pullEvent()
      if ev == "http_success" and p1 == u then
        if p2 then
          if type(p2.getResponseCode) == "function" then
            local code = p2.getResponseCode()
            if code ~= 200 then pcall(p2.close); return nil, "HTTP "..code end
          end
          local ok2, body = pcall(p2.readAll); pcall(p2.close)
          if ok2 and type(body) == "string" then return body end
          return nil, "read failed"
        end
        return nil, "empty response"
      elseif ev == "http_failure" and p1 == u then
        if p3 then pcall(p3.close) end
        return nil, tostring(p2 or "http_failure")
      elseif ev == "timer" and p1 == timer then
        if type(http.cancelRequest) == "function" then pcall(http.cancelRequest, u) end
        return nil, "timeout after "..timeout_s.."s"
      end
    end
  end

  local function try_sync(u)
    local ok, r = pcall(http.get, u)
    if not ok or not r then return nil, "http.get failed" end
    if type(r.getResponseCode) == "function" then
      local code = r.getResponseCode()
      if code ~= 200 then pcall(r.close); return nil, "HTTP "..code end
    end
    local ok2, body = pcall(r.readAll); pcall(r.close)
    if ok2 and type(body) == "string" then return body end
    return nil, "read failed"
  end

  local last_err
  for attempt = 1, retries do
    local t = tostring(os.epoch and os.epoch("utc") or os.time())
    local rnd = tostring(math.random(100000, 999999))
    local sep = url:find("?", 1, true) and "&" or "?"
    local u = url .. sep .. "xr_cb=" .. attempt .. "-" .. t .. "-" .. rnd
    local body, err = use_async and try_async(u) or try_sync(u)
    if body then return body, url end
    last_err = err
    if attempt < retries then os.sleep(delays[attempt] or 20) end
  end
  return nil, tostring(last_err or "download failed")
end

function M.download_file(rel_path, sha, opts)
  local base = sha
    and ("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/" .. sha .. "/xreactor/")
    or  ("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/")
  local urls = { base .. rel_path }
  if sha then
    urls[2] = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/" .. rel_path
  end
  for _, url in ipairs(urls) do
    local body, err = M.download(url, opts)
    if body and not M.is_html(body) then return body, url end
  end
  return nil, "alle URLs fehlgeschlagen fuer " .. rel_path
end

return M
