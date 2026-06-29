-- installer/auto_update.lua
-- Periodischer Versions-Check und automatisches Update.
-- Läuft OHNE Bootstrap — nur fs, http, os, print verfügbar.

local M = {}

local ARMING_PATH   = "/xreactor/config/remote_update.lua"
local RELEASE_PATH  = "/xreactor/release.lua"
local GITHUB_API    = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local GITHUB_RAW    = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

local function log(msg) pcall(print, "[AUTO] " .. tostring(msg)) end

local function arming()
  if not fs or not fs.exists(ARMING_PATH) then return nil end
  local f = fs.open(ARMING_PATH, "r"); if not f then return nil end
  local src = f.readAll(); f.close()
  local loader = load(src, "=arm", "t", {}); if not loader then return nil end
  local ok, cfg = pcall(loader)
  if not ok or type(cfg) ~= "table" or cfg.enabled ~= true then return nil end
  return cfg
end

local function resolve_sha()
  if not http or type(http.get) ~= "function" then return nil end
  for attempt = 1, 3 do
    local ok, r = pcall(http.get, GITHUB_API, nil, { timeout = 10 })
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

local function read_version(path)
  if not fs or not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local src = f.readAll(); f.close()
  return tonumber(src:match("manifest_version%s*=%s*(%d+)"))
end

local function fetch_remote_version(sha)
  local urls = sha and {
    GITHUB_RAW .. sha .. "/xreactor/release.lua",
    GITHUB_RAW .. "beta/xreactor/release.lua",
  } or { GITHUB_RAW .. "beta/xreactor/release.lua" }
  for _, url in ipairs(urls) do
    for attempt = 1, 3 do
      local ok, r = pcall(http.get, url, nil, { timeout = 10 })
      if ok and r then
        local ok2, body = pcall(r.readAll); pcall(r.close)
        if ok2 and type(body) == "string" and #body > 10 then
          local s = body:sub(1, 200):lower()
          if not s:find("<html", 1, true) and not s:find("<!doctype", 1, true) then
            local v = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
            if v then return v end
          end
        end
      end
      if attempt < 3 then os.sleep(3) end
    end
  end
  return nil
end

local function run_update(sha)
  local urls = sha and {
    GITHUB_RAW .. sha .. "/installer",
    GITHUB_RAW .. "beta/installer",
  } or { GITHUB_RAW .. "beta/installer" }
  for _, url in ipairs(urls) do
    for attempt = 1, 4 do
      local delays = {2, 5, 10, 20}
      local ok, r = pcall(http.get, url, nil, { timeout = 20 })
      if ok and r then
        local ok2, body = pcall(r.readAll); pcall(r.close)
        if ok2 and type(body) == "string" and #body > 100 then
          local s = body:sub(1, 200):lower()
          if not s:find("<html", 1, true) and not s:find("<!doctype", 1, true) then
            local tmp = "/xreactor_auto_update_installer.lua"
            local f = fs.open(tmp, "w")
            if f then
              pcall(function() f.write(body) end); pcall(f.close)
              _G.__xreactor_remote_update = true
              local ok_run = pcall(shell.run, tmp)
              pcall(fs.delete, tmp)
              if ok_run then log("Update OK — Neustart"); os.sleep(1); os.reboot(); return true end
            end
          end
        end
      end
      if attempt < 4 then os.sleep(delays[attempt] or 20) end
    end
  end
  return false, "alle Download-Versuche fehlgeschlagen"
end

function M.make_loop(interval_s)
  interval_s = tonumber(interval_s) or 120
  return function()
    log("Loop gestartet (Intervall " .. interval_s .. "s)")
    while true do
      local timer = os.startTimer(interval_s)
      repeat local ev, id = os.pullEvent() until ev == "timer" and id == timer

      local cfg = arming()
      if not cfg then
        log("nicht armed — skip")
      elseif cfg.auto_update ~= true then
        log("auto_update deaktiviert — skip")
      else
        log("Prüfe Version...")
        local sha      = resolve_sha()
        local remote_v = fetch_remote_version(sha)
        local local_v  = read_version(RELEASE_PATH)
        if not remote_v then
          log("Remote-Version nicht abrufbar")
        elseif not local_v then
          log("Lokale Version unbekannt")
        elseif remote_v <= local_v then
          log("Aktuell (lokal=v" .. local_v .. " remote=v" .. remote_v .. ")")
        else
          log("NEU: lokal=v" .. local_v .. " → remote=v" .. remote_v)
          local success = false
          for attempt = 1, 3 do
            log("Versuch " .. attempt .. "/3")
            local ok_u, err_u = run_update(sha)
            if ok_u then success = true; break end
            log("Fehlgeschlagen: " .. tostring(err_u))
            if attempt < 3 then os.sleep(5) end
          end
          if not success then log("Alle Versuche fehlgeschlagen — Pause 60s"); os.sleep(60) end
        end
      end
    end
  end
end

return M
