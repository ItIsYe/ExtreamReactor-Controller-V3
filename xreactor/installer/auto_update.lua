-- Sole managed updater for periodic and command-triggered installations.
-- Runs beside the role coroutine and therefore only uses CC:Tweaked APIs.

local M = {}

local ARMING_PATH = "/xreactor/config/remote_update.lua"
local RELEASE_PATH = "/xreactor/release.lua"
local TEMP_INSTALLER = "/xreactor_auto_update_installer.lua"
local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"
local SOURCE_REF = "beta"
local UPDATE_EVENT = "xreactor_remote_update_requested"

-- Fix: FUEL/REPROCESSOR quiesce via redstone_router.lua's begin_quiesce()/
-- poll_quiesce() -- confirming EVERY known valve BLOCKED over a wireless
-- ACK round trip, with its own SAFETY_CONFIRM_TIMEOUT_MS=15000ms budget PER
-- confirmation attempt (see nodes/fuel/redstone_router.lua) before it
-- re-requests a fresh batch. The previous 20s deadline here left barely any
-- margin over a SINGLE 15s attempt -- any retry, ACK loss, or ongoing
-- delivery competing for the same valves reliably blew the 20s budget. The
-- role-side handshake state (core/update_handshake.lua) resets to IDLE on
-- timeout, but the router's OWN quiesce progress (self._state.quiesce)
-- survives untouched, so this doesn't need to be "instant" -- it only needs
-- enough room for a few full confirmation rounds. 60s covers 4x the
-- internal 15s budget. RT/VALVE/WATER/MASTER/LOG quiesce locally/
-- synchronously and return via wait_for_runtime_stopped() as soon as they
-- confirm, well before this ceiling -- raising it costs them nothing.
local QUIESCE_TIMEOUT_S = 60

local function log(message)
  pcall(print, "[AUTO] " .. tostring(message))
end

local function load_handshake_lib()
  local ok, lib = pcall(dofile, "/xreactor/core/update_handshake.lua")
  if not ok or type(lib) ~= "table" then return nil, tostring(lib) end
  return lib
end

local function close_response(response)
  if response then pcall(response.close) end
end

local function read_response(response)
  if not response then return nil, "empty response" end
  if type(response.getResponseCode) == "function" then
    local ok_code, code = pcall(response.getResponseCode)
    if ok_code and type(code) == "number" and (code < 200 or code >= 300) then
      close_response(response)
      return nil, "HTTP " .. tostring(code)
    end
  end
  local ok, body = pcall(response.readAll)
  close_response(response)
  if not ok or type(body) ~= "string" or body == "" then
    return nil, "readAll failed"
  end
  return body
end

-- http.request is event-driven and therefore safe inside parallel.waitForAll.
-- The synchronous fallback intentionally uses the documented CC:Tweaked
-- signature http.get(url), without an options table masquerading as the
-- binary flag.
local function http_get_async(url)
  if http and type(http.request) == "function" then
    local ok_call, started, request_err = pcall(http.request, url)
    if not ok_call or started ~= true then
      return nil, tostring(request_err or started or "http.request failed")
    end

    local timer = os.startTimer(15)
    while true do
      local event, p1, p2, p3 = os.pullEvent()
      if event == "http_success" and p1 == url then
        if os.cancelTimer then pcall(os.cancelTimer, timer) end
        return read_response(p2)
      elseif event == "http_failure" and p1 == url then
        if os.cancelTimer then pcall(os.cancelTimer, timer) end
        close_response(p3)
        return nil, tostring(p2 or "http_failure")
      elseif event == "timer" and p1 == timer then
        return nil, "timeout"
      end
    end
  end

  if not http or type(http.get) ~= "function" then
    return nil, "http unavailable"
  end
  local ok, response = pcall(http.get, url)
  if not ok or not response then return nil, tostring(response or "http.get failed") end
  return read_response(response)
end

local function load_arming()
  if not fs or not fs.exists(ARMING_PATH) then return nil, "not armed" end
  local handle = fs.open(ARMING_PATH, "r")
  if not handle then return nil, "arming config unreadable" end
  local source = handle.readAll()
  handle.close()

  local loader, load_err = load(source, "=remote_update_arming", "t", {})
  if not loader then return nil, "arming parse failed: " .. tostring(load_err) end
  local ok, config = pcall(loader)
  if not ok or type(config) ~= "table" then return nil, "arming config invalid" end
  if config.enabled ~= true then return nil, "not armed" end
  return config
end

local function cache_bust(url, attempt)
  local separator = url:find("?", 1, true) and "&" or "?"
  local timestamp = os.epoch and os.epoch("utc") or os.time()
  return url .. separator .. "xr_cb=" .. tostring(attempt or 1) .. "_" .. tostring(timestamp)
end

local function is_html(body)
  if type(body) ~= "string" then return false end
  local prefix = body:sub(1, 200):lower()
  return prefix:find("<html", 1, true) ~= nil
    or prefix:find("<!doctype", 1, true) ~= nil
end

local function read_version(path)
  if not fs or not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local source = handle.readAll()
  handle.close()
  return tonumber(source:match("manifest_version%s*=%s*(%d+)"))
end

local function fetch_remote_version()
  local base_url = GITHUB_RAW .. SOURCE_REF .. "/xreactor/release.lua"
  local last_error = "remote release unavailable"
  for attempt = 1, 3 do
    local body, err = http_get_async(cache_bust(base_url, attempt))
    if body and not is_html(body) then
      local version = tonumber(body:match("manifest_version%s*=%s*(%d+)"))
      if version then return version end
      last_error = "release has no manifest_version"
    else
      last_error = err or "unexpected HTML"
    end
    if attempt < 3 then os.sleep(3) end
  end
  return nil, last_error
end

local function request_and_await_quiesce(handshake)
  if type(handshake) ~= "table" then return false, "missing handshake" end
  local update_handshake, load_err = load_handshake_lib()
  if not update_handshake then
    return false, "update handshake unavailable: " .. tostring(load_err)
  end

  local requested, request_err = update_handshake.request_quiesce(handshake)
  if requested ~= true then return false, request_err or "quiesce request failed" end
  log("Quiesce angefordert -- warte auf RUNTIME_STOPPED...")
  if update_handshake.wait_for_runtime_stopped(handshake, QUIESCE_TIMEOUT_S) then
    log("Quiesce bestaetigt (RUNTIME_STOPPED)")
    return true
  end

  -- The timeout can coincide with the role's final state transition. Once
  -- safe outputs were applied, reboot is the only valid way to restore a
  -- stopped runtime. Otherwise cancel the still-live request cleanly.
  if handshake.quiesce_attempted == true
      or handshake.state == update_handshake.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == update_handshake.STATE.RUNTIME_STOPPED then
    log("Quiesce-Timeout nach Sicherheitsversuch -- Runtime wird sicher neu gestartet")
    if os and type(os.reboot) == "function" then os.reboot() end
    return false, "runtime stopped at quiesce timeout"
  end
  if update_handshake.reset(handshake) ~= true then
    log("Quiesce-Reset fehlgeschlagen -- Runtime wird sicher neu gestartet")
    if os and type(os.reboot) == "function" then os.reboot() end
    return false, "quiesce reset failed"
  end
  log("Quiesce-Timeout -- Rolle bleibt aktiv; Update bleibt vorgemerkt")
  return false, "quiesce timeout"
end

local function has_temp_space(bytes_needed)
  if not fs or type(fs.getFreeSpace) ~= "function" then return true end
  local ok, free = pcall(fs.getFreeSpace, "/")
  if not ok then return true end
  if type(free) == "string" then
    if free:lower() == "unlimited" then return true end
    free = tonumber(free)
  end
  if type(free) ~= "number" or free < 0 then return true end
  return free >= bytes_needed
end

local LOG_DIR = "/xreactor_logs"

local function dir_size(path)
  if not fs.exists(path) then return 0 end
  local ok_is_dir, is_dir = pcall(fs.isDir, path)
  if not ok_is_dir then return 0 end
  if not is_dir then
    local ok_size, size = pcall(fs.getSize, path)
    return (ok_size and type(size) == "number") and size or 0
  end
  local ok_list, entries = pcall(fs.list, path)
  if not ok_list or type(entries) ~= "table" then return 0 end
  local total = 0
  for _, name in ipairs(entries) do
    total = total + dir_size(path .. "/" .. name)
  end
  return total
end

-- Fix: same last-resort reclaim as installer/stage.lua's reclaim() (see
-- there for the full history/rationale -- explicit user request after
-- repeated "out of space" aborts). The managed auto-updater has its own,
-- separate temp-space check here (writing the freshly downloaded
-- installer bootstrap to TEMP_INSTALLER before dofile()-ing it) and
-- didn't share that logic, so a node whose logs had re-accumulated could
-- still fail every attempt with "insufficient space for temporary
-- installer" even after the manual-install path was already fixed to
-- self-heal. Mirrored here rather than requiring stage.lua: this file is
-- deliberately self-contained (see header comment). Only /xreactor_logs,
-- only as a last resort after the plain space check already failed, and
-- every actual deletion is logged -- never silent.
local function ensure_temp_space(bytes_needed)
  if has_temp_space(bytes_needed) then return true end
  if fs.exists(LOG_DIR) then
    local logs_bytes = dir_size(LOG_DIR)
    if logs_bytes > 0 then
      pcall(fs.delete, LOG_DIR)
      if not fs.exists(LOG_DIR) then
        log(string.format("/xreactor_logs geloescht (%d bytes) -- Speicher war sonst nicht ausreichend", logs_bytes))
      end
    end
  end
  return has_temp_space(bytes_needed)
end

local function run_update()
  local base_url = GITHUB_RAW .. SOURCE_REF .. "/installer"
  local last_error = "installer unavailable"
  if fs.exists(TEMP_INSTALLER) then pcall(fs.delete, TEMP_INSTALLER) end

  for attempt = 1, 4 do
    local body, err = http_get_async(cache_bust(base_url, attempt))
    if body and #body > 100 and not is_html(body) then
      if not ensure_temp_space(#body + 1024) then
        last_error = "insufficient space for temporary installer"
      else
        local handle = fs.open(TEMP_INSTALLER, "w")
        if not handle then
          last_error = "temporary installer cannot be opened"
        else
          local write_ok, write_err = pcall(function() handle.write(body) end)
          pcall(handle.close)
          if not write_ok then
            last_error = "temporary installer write failed: " .. tostring(write_err)
            pcall(fs.delete, TEMP_INSTALLER)
          else
            local previous_remote = rawget(_G, "__xreactor_remote_update")
            local previous_ref = rawget(_G, "__xreactor_forced_ref")
            _G.__xreactor_remote_update = true
            _G.__xreactor_forced_ref = SOURCE_REF
            local run_ok, result = pcall(dofile, TEMP_INSTALLER)
            _G.__xreactor_remote_update = previous_remote
            _G.__xreactor_forced_ref = previous_ref
            pcall(fs.delete, TEMP_INSTALLER)

            if run_ok and result ~= false then
              log("Update abgeschlossen -- Neustart")
              os.sleep(1)
              os.reboot()
              return true
            end
            last_error = run_ok and "installer returned false"
              or ("installer error: " .. tostring(result))
          end
        end
      end
    else
      last_error = tostring(err or (body and "invalid installer response" or "no body"))
    end

    log("Installer-Download " .. attempt .. "/4 fehlgeschlagen: " .. last_error)
    if attempt < 4 then os.sleep(({ 2, 5, 10 })[attempt] or 10) end
  end
  return false, last_error
end

local function reboot_after_stopped_failure(reason)
  log("Update nach gestoppter Runtime fehlgeschlagen: " .. tostring(reason)
    .. " -- Neustart aktiviert die alte oder journalgeschuetzte Installation")
  os.sleep(2)
  if os and type(os.reboot) == "function" then os.reboot() end
end

local function perform_update(handshake, consume_remote)
  local quiesced, quiesce_err = request_and_await_quiesce(handshake)
  if not quiesced then return false, quiesce_err end

  if consume_remote then
    local update_handshake = load_handshake_lib()
    if update_handshake then update_handshake.consume_remote_update(handshake) end
  end

  local last_error
  for attempt = 1, 3 do
    local ok, err = run_update()
    if ok then return true end
    last_error = err
    log("Update-Lauf " .. attempt .. "/3 fehlgeschlagen: " .. tostring(err))
    if attempt < 3 then os.sleep(5) end
  end
  reboot_after_stopped_failure(last_error or "installation failed")
  return false, last_error
end

local function do_periodic_check(handshake)
  local config, arm_err = load_arming()
  if not config then log("Auto-Update uebersprungen: " .. tostring(arm_err)); return end
  if config.auto_update ~= true then return end

  local remote_version, remote_err = fetch_remote_version()
  local local_version = read_version(RELEASE_PATH)
  if not remote_version then
    log("Remote-Version nicht abrufbar: " .. tostring(remote_err))
  elseif not local_version then
    log("Lokale Version unbekannt")
  elseif remote_version > local_version then
    log("Neue Version: v" .. local_version .. " -> v" .. remote_version .. " @ " .. SOURCE_REF)
    perform_update(handshake, false)
  end
end

local function do_remote_request(handshake)
  local update_handshake, load_err = load_handshake_lib()
  if not update_handshake then error("remote request: " .. tostring(load_err)) end
  local meta = update_handshake.peek_remote_update(handshake)
  if not meta then return end

  local config, arm_err = load_arming()
  if not config then
    update_handshake.consume_remote_update(handshake)
    log("Vorgemerktes Remote-Update verworfen: " .. tostring(arm_err))
    return
  end

  log("Vorgemerktes Remote-Update startet @ " .. SOURCE_REF
    .. " trigger=" .. tostring(meta.trigger or "?"))
  perform_update(handshake, true)
end

local function recover_unexpected(handshake, label, err)
  log(label .. " Fehler abgefangen: " .. tostring(err):sub(1, 160))
  if type(handshake) ~= "table" then return end
  local update_handshake = load_handshake_lib()
  if not update_handshake then return end
  if handshake.state == update_handshake.STATE.SAFE_OUTPUTS_APPLIED
      or handshake.state == update_handshake.STATE.RUNTIME_STOPPED then
    reboot_after_stopped_failure(label .. ": " .. tostring(err))
  elseif handshake.state == update_handshake.STATE.UPDATE_REQUESTED
      or handshake.state == update_handshake.STATE.QUIESCE_REQUESTED then
    update_handshake.reset(handshake)
  end
end

local function safe_call(handshake, label, callback)
  local ok, err = pcall(callback, handshake)
  if not ok then recover_unexpected(handshake, label, err) end
end

function M.make_loop(interval_s, handshake)
  interval_s = tonumber(interval_s) or 120
  return function()
    log("Loop gestartet (Intervall " .. interval_s .. "s)")
    local next_delay = 30
    while true do
      -- Handles requests queued before this coroutine began waiting.
      safe_call(handshake, "remote_update", do_remote_request)

      local timer = os.startTimer(next_delay)
      next_delay = interval_s
      while true do
        local event, id = os.pullEvent()
        if event == UPDATE_EVENT then
          safe_call(handshake, "remote_update", do_remote_request)
        elseif event == "timer" and id == timer then
          safe_call(handshake, "periodic_update", do_periodic_check)
          break
        end
      end
    end
  end
end

return M
