-- installer/http.lua
-- Download-Modul: ein vom Aufrufer gewaehlter Ref, Retries, HTML-Check
-- CC:Tweaked kompatibel: http.get(url) ohne timeout-Parameter

local M = {}

local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

-- HTML-Erkennung (CDN-Fehlerseiten)
function M.is_html(body)
  if type(body) ~= "string" then return false end
  local s = body:sub(1, 200):lower()
  return s:find("<html", 1, true) ~= nil or s:find("<!doctype", 1, true) ~= nil
end

-- Einfacher synchroner Download einer URL.
-- Gibt body oder nil, err zurück.
local function try_once(url)
  if not http or type(http.get) ~= "function" then return nil, "no http" end
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil, "http.get failed" end
  -- Response-Code prüfen wenn verfügbar
  if type(r.getResponseCode) == "function" then
    local code = r.getResponseCode()
    if code ~= 200 then pcall(r.close); return nil, "HTTP " .. tostring(code) end
  end
  local ok2, body = pcall(r.readAll); pcall(r.close)
  if not ok2 or type(body) ~= "string" then return nil, "read failed" end
  return body
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
