-- installer/auto_update.lua
-- Managed periodic + queued remote updater. Runs without bootstrap.

local M = {}

local ARMING_PATH = "/xreactor/config/remote_update.lua"
local RELEASE_PATH = "/xreactor/release.lua"
local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"
local SOURCE_REF = "beta"
local UPDATE_EVENT = "xreactor_remote_update_requested"

local function log(msg) pcall(print, "[AUTO] " .. tostring(msg)) end

local function load_handshake_lib()
  local ok, lib = pcall(dofile, "/xreactor/core/update_handshake.lua")
  if not ok or type(lib) ~= "table" then return nil, tostring(lib) end
  return lib
end

local function http_get_async(url)
  if not http or type(http.request) ~= "function" then
    if not http or type(http.get) ~= "function" then return nil, "http unavailable" end
    local ok, r = pcall(http.get, url, nil, { timeout = 15 })
    if not ok or not r then return nil, "http.get failed" end
    local ok2, body = pcall(r.readAll); pcall(r.close)
    if ok2 and type(body) == "string" then return body end
    return nil, "readAll failed"
  end
  local ok_req = pcall(http.request, url)
  if not ok_req then return nil, "http.request failed" end
  local timer = os.startTimer(15)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "http_success" and p1 == url then
      if not p2 then return nil, "empty response" end
      local ok2, body = pcall(p2.readAll); pcall(p2.close)
      if ok2 and type(body) == "string" and #body > 0 then return body end
      return nil, "readAll failed"
    elseif ev == "http_failure" and p1 == url then
      if p3 then pcall(p3.close) end
      return nil, tostring(p2 or "http_failure")
    elseif ev == "timer" and p1 == timer then
      return nil, "timeout"
    end
  end
end

local function arming()
  if not fs or not fs.exists(ARMING_PATH) then return nil, "not armed" end
  local f = fs.open(ARMING_PATH, "r")
  if not f then return nil, "arming config unreadable" end
  local src = f.readAll(); f.close()
  local loader, lerr = load(src, "=arm", "t", _ENV)
  if not loader then return nil, "arming parse failed: " .. tostring(lerr) end
  local ok, cfg = pcall(loader)
  if not ok or type(cfg) ~= "table" then return nil, "arming config invalid" end
  if cfg.enabled ~= true then return nil, "not armed" end
  return cfg
end

local function cache_bust(url, attempt)
  local sep = url:find("?", 1, true) and "&" or "?"
  local t = tostring(os.epoch and os.epoch("utc") or os.time())
  return url .. sep .. "xr_cb=" .. tostring(attempt or 1) .. "_" .. t
end

local function read_version(path)
  if not fs or not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local src = f.readAll(); f.close()
  return tonumber(src:match("manifest_version%s*=%s*(%d+)"))
end

local function fetch_remote_version(ref)
  local url = GITHUB_RAW .. tostring(ref or SOURCE_REF) .. "/xreactor/release.lua"
  for attempt = 1, 3 do
    local body, err = http_get_async(cache_bust(url, attempt))
    if body then
      local s = body:sub(1, 200):lower()
      if not s:find("<html", 1, true) and not s:find("<!doctype", 1, true) then
        local v = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
        if v then return v end
      end
    end
    if attempt < 3 then os.sleep(3) end
  end
  return nil, "remote release unavailable"
end

local function request_and_await_quiesce(handshake)
  if not handshake then return false, "missing handshake" end
  local update_handshake, load_err = load_handshake_lib()
  if not update_handshake then
    return false, "update_handshake unavailable: " .. tostring(load_err)
  end
  local requested, request_err = update_handshake.request_quiesce(handshake)
  if requested ~= true then return false, request_err or "quiesce request failed" end
  log("Quiesce angefordert -- warte auf RUNTIME_STOPPED...")
  local confirmed = update_handshake.wait_for_runtime_stopped(handshake, 20)
  if confirmed then
    log("Quiesce bestaetigt (RUNTIME_STOPPED)")
    return true
  end

  -- Do not leave a live role with a latent QUIESCE_REQUESTED after the updater
  -- has stopped waiting. If it somehow reached the safe/stopped phase during
  -- the timeout boundary, reboot instead of leaving the role gone.
  if handshake.state == update_handshake.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == update_handshake.STATE.RUNTIME_STOPPED then
    log("Quiesce-Timeout an Stop-Grenze -- Neustart zur sicheren Runtime-Wiederherstellung")
    if os and type(os.reboot) == "function" then os.reboot() end
    return false, "runtime stopped at quiesce timeout"
  end
  update_handshake.reset(handshake)
  log("Quiesce-Timeout -- Request zurueckgesetzt; Rolle bleibt aktiv")
  return false, "quiesce timeout"
end

local function free_space_root()
  if not (fs and type(fs.getFreeSpace) == "function") then return nil end
  local ok, v = pcall(fs.getFreeSpace, "/")
  if not ok then return nil end
  if type(v) == "string" then
    if v:lower() == "unlimited" then return math.huge end
    v = tonumber(v)
  end
  if type(v) == "number" then return v < 0 and math.huge or v end
  return nil
end

local function reclaim(needed)
  local free = free_space_root()
  if free and free >= needed then return true end
  if fs.exists("/xreactor_backup_prev") then pcall(fs.delete, "/xreactor_backup_prev") end
  if fs.exists("/xreactor_stage") then pcall(fs.delete, "/xreactor_stage") end
  free = free_space_root()
  return free == nil or free >= needed
end

local function run_update(ref)
  ref = tostring(ref or SOURCE_REF)
  local url = GITHUB_RAW .. ref .. "/installer"
  local last_err = "unknown"
  local tmp = "/xreactor_auto_update_installer.lua"
  if fs.exists(tmp) then pcall(fs.delete, tmp) end

  for attempt = 1, 4 do
    local body, err = http_get_async(cache_bust(url, attempt))
    if body and #body > 100 then
      local s = body:sub(1, 200):lower()
      if s:find("<html", 1, true) or s:find("<!doctype", 1, true) then
        last_err = "unexpected HTML"
      elseif not reclaim(#body + 1024) then
        last_err = "insufficient space"
      else
        local f = fs.open(tmp, "w")
        if not f then
          last_err = "temp open failed"
        else
          local ok_write, write_err = pcall(f.write, body)
          pcall(f.close)
          if not ok_write then
            last_err = "temp write failed: " .. tostring(write_err)
            pcall(fs.delete, tmp)
          else
            local previous_forced_ref = rawget(_G, "__xreactor_forced_ref")
            _G.__xreactor_remote_update = true
            _G.__xreactor_forced_ref = ref
            local ok_call, result = pcall(dofile, tmp)
            _G.__xreactor_remote_update = nil
            _G.__xreactor_forced_ref = previous_forced_ref
            pcall(fs.delete, tmp)
            if ok_call and result ~= false then
              log("Update OK -- Neustart")
              os.sleep(1)
              os.reboot()
              return true
            end
            last_err = ok_call and "installer returned false" or ("dofile error: " .. tostring(result))
          end
        end
      end
    else
      last_err = tostring(err or (body and ("response too short: " .. #body) or "no body"))
    end
    log("Update-Versuch " .. attempt .. "/4 fehlgeschlagen: " .. tostring(last_err))
    if attempt < 4 then os.sleep(({2, 5, 10})[attempt] or 10) end
  end
  return false, last_err
end

local function recover_after_quiesced_failure(handshake, reason)
  if handshake then
    log("Updater fehlgeschlagen nachdem Runtime gestoppt wurde: " .. tostring(reason)
      .. " -- Neustart stellt die unveraenderte/rollback-geschuetzte Runtime wieder her")
    os.sleep(2)
    if os and type(os.reboot) == "function" then os.reboot() end
  end
end

local function perform_update(handshake, ref, consume_remote)
  local quiesced, qerr = request_and_await_quiesce(handshake)
  if not quiesced then return false, qerr end

  if consume_remote then
    local update_handshake = load_handshake_lib()
    if update_handshake then update_handshake.consume_remote_update(handshake) end
  end

  local success, last_err = false, nil
  for attempt = 1, 3 do
    local ok_u, err_u = run_update(ref)
    if ok_u then success = true; break end
    last_err = err_u
    if attempt < 3 then os.sleep(5) end
  end
  if not success then recover_after_quiesced_failure(handshake, last_err or "install failed") end
  return success, last_err
end

local function do_periodic_check(handshake)
  local cfg, arm_err = arming()
  if not cfg then log("Auto-Update skip: " .. tostring(arm_err)); return end
  if cfg.auto_update ~= true then return end

  local remote_v, remote_err = fetch_remote_version(SOURCE_REF)
  local local_v = read_version(RELEASE_PATH)
  if not remote_v then log("Remote-Version nicht abrufbar: " .. tostring(remote_err)); return end
  if not local_v then log("Lokale Version unbekannt"); return end
  if remote_v <= local_v then return end

  log("NEU: v" .. local_v .. " -> v" .. remote_v .. " @ " .. SOURCE_REF)
  perform_update(handshake, SOURCE_REF, false)
end

local function do_remote_request(handshake)
  local update_handshake, load_err = load_handshake_lib()
  if not update_handshake then error("remote request: " .. tostring(load_err)) end
  local meta = update_handshake.peek_remote_update(handshake)
  if not meta then return end

  local cfg, arm_err = arming()
  if not cfg then
    update_handshake.consume_remote_update(handshake)
    log("Queued Remote-Update verworfen: " .. tostring(arm_err))
    return
  end

  log("Queued Remote-Update startet @ " .. SOURCE_REF
    .. " trigger=" .. tostring(meta.trigger or "?"))
  perform_update(handshake, SOURCE_REF, true)
end

local function recover_unexpected(handshake, label, err)
  log(label .. " Fehler abgefangen: " .. tostring(err):sub(1, 160))
  if not handshake then return end
  local update_handshake = load_handshake_lib()
  if not update_handshake then return end
  if handshake.state == update_handshake.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == update_handshake.STATE.RUNTIME_STOPPED then
    recover_after_quiesced_failure(handshake, label .. ": " .. tostring(err))
  elseif handshake.state == update_handshake.STATE.UPDATE_REQUESTED
      or handshake.state == update_handshake.STATE.QUIESCE_REQUESTED then
    -- The role is still running; cancel the abandoned quiesce request so it
    -- cannot stop later with no updater waiting for it.
    update_handshake.reset(handshake)
  end
end

local function safe_call(handshake, label, fn)
  local ok, err = pcall(fn, handshake)
  if not ok then recover_unexpected(handshake, label, err) end
end

function M.make_loop(interval_s, handshake)
  interval_s = tonumber(interval_s) or 120
  return function()
    log("Loop gestartet (Intervall " .. interval_s .. "s)")
    local next_delay = 30
    while true do
      -- A queued request can already exist before this iteration starts.
      safe_call(handshake, "remote_update", do_remote_request)

      local timer = os.startTimer(next_delay)
      next_delay = interval_s
      local periodic_due = false
      while true do
        local ev, id = os.pullEvent()
        if ev == UPDATE_EVENT then
          safe_call(handshake, "remote_update", do_remote_request)
        elseif ev == "timer" and id == timer then
          periodic_due = true
          break
        end
      end
      if periodic_due then
        safe_call(handshake, "periodic_update", do_periodic_check)
      end
    end
  end
end

return M
