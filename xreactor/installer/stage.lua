-- installer/stage.lua
-- Dateien herunterladen und schreiben. Atomic write, Speicher-Check.

local M = {}
local WRITE_BUFFER = 1024

local function free_space()
  if not fs.getFreeSpace then return nil end
  local ok, v = pcall(fs.getFreeSpace, "/")
  if not ok then return nil end
  if type(v) == "string" then
    if v:lower() == "unlimited" then return math.huge end
    v = tonumber(v)
  end
  if type(v) == "number" then return v < 0 and math.huge or v end
  return nil
end
M.free_space = free_space

-- Recursive size, used only for the space-shortage diagnostic below --
-- never for a decision to delete anything.
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

-- Absoluter letzter Ausweg in reclaim(): nur wenn die installer-eigenen
-- Zwischenverzeichnisse allein nicht reichen, nur genau dieser eine Pfad
-- (kein /disk/xreactor_logs, keine anderen Nutzerdaten), und jede
-- tatsaechliche Loeschung wird laut ueber print() gemeldet statt still zu
-- passieren. Reicht selbst das nicht, bleibt reclaim() fail-closed mit
-- klarem Diagnosefehler statt Logs unbegruendet zu vernichten.
local function reclaim_logs(needed_after)
  local logs_bytes = dir_size("/xreactor_logs")
  if logs_bytes <= 0 or not fs.exists("/xreactor_logs") then return false end
  pcall(fs.delete, "/xreactor_logs")
  local cleared = not fs.exists("/xreactor_logs")
  if cleared then
    pcall(print, string.format(
      "[INSTALL] /xreactor_logs geloescht (%d bytes) -- Speicher war sonst nicht ausreichend (benoetigt: %d bytes)",
      logs_bytes, needed_after))
  end
  return cleared
end

-- Shared with installer/init.lua: any early fs write (e.g. makeDir() for the
-- recovery directory, BEFORE /xreactor is deleted) can hit the exact same
-- space shortage as M.write() below, with no "needed" byte count of its own
-- to report -- callers that only know they're low on space, not how much
-- they were trying to write, pass needed=nil.
function M.space_diagnostic(free, needed)
  local diag = needed and string.format("free=%d needed=%d", free, needed)
    or string.format("free=%d", free)
  local logs_bytes = dir_size("/xreactor_logs")
  if logs_bytes > 0 then
    diag = diag .. string.format(" -- /xreactor_logs still uses %d bytes", logs_bytes)
  end
  return diag
end

local function reclaim(needed)
  local free = free_space()
  if free and free >= needed then return true end
  if fs.exists("/xreactor_backup_prev") then pcall(fs.delete, "/xreactor_backup_prev") end
  if fs.exists("/xreactor_stage")       then pcall(fs.delete, "/xreactor_stage") end
  free = free_space()
  if free == nil or free >= needed then return true end
  local logs_were_cleared = reclaim_logs(needed)
  if logs_were_cleared then
    free = free_space()
    if free == nil or free >= needed then return true end
  end
  local diag = M.space_diagnostic(free, needed)
  if logs_were_cleared then
    diag = diag .. " -- /xreactor_logs was already cleared and it still wasn't enough"
  end
  return false, diag
end
M.reclaim = reclaim

function M.write(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  local reclaimed, reclaim_diag = reclaim(#content + WRITE_BUFFER)
  if not reclaimed then
    return false, "not enough space for " .. path .. " (" .. tostring(reclaim_diag) .. ")"
  end
  local tmp = path .. ".xr_tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "open failed: " .. tmp end
  local write_ok, write_err = pcall(function() f.write(content) end)
  pcall(f.close)
  if not write_ok then pcall(fs.delete, tmp); return false, tostring(write_err) end

  -- Die alte Datei wird zu einem Backup-Namen VERSCHOBEN statt geloescht --
  -- "path" existiert dadurch durchgehend, entweder als alte oder neue
  -- Version, statt fuer ein Zeitfenster ganz zu fehlen. Die alte Datei wird
  -- nur geloescht, wenn sie tatsaechlich am Backup-Pfad wiederzufinden ist
  -- (per fs.exists verifiziert, nicht nur am pcall-Erfolg von fs.move) --
  -- schlaegt das Backup fehl, bricht M.write() sofort mit klarem Fehler ab.
  local backup = path .. ".xr_prev"
  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(backup) then
      pcall(fs.delete, backup)
      if fs.exists(backup) then
        pcall(fs.delete, tmp)
        return false, "could not clear stale backup: " .. backup
      end
    end
    pcall(fs.move, path, backup)
    if not fs.exists(backup) then
      pcall(fs.delete, tmp)
      return false, "backup move failed: " .. path .. " -> " .. backup
    end
  end

  local ok2, mv_err = pcall(fs.move, tmp, path)
  if not ok2 or not fs.exists(path) then
    pcall(fs.delete, tmp)
    -- Neue Datei konnte nicht an ihren Platz — altes Backup zurueckholen,
    -- damit "path" nicht dauerhaft fehlt.
    if had_old and fs.exists(backup) and not fs.exists(path) then
      pcall(fs.move, backup, path)
    end
    return false, "move failed: " .. tostring(mv_err)
  end
  if had_old and fs.exists(backup) then pcall(fs.delete, backup) end
  return true
end

function M.read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local c = f.readAll(); f.close(); return c
end

-- "crc32_fn" wird optional vom Aufrufer durchgereicht (installer/init.lua
-- uebergibt manifest.lua's M.crc32) -- kein dofile()/require() hier, um
-- stage.lua nicht von manifest.lua abhaengig zu machen. Ohne crc32_fn
-- pruefen Existenz/Groesse/Syntax allein nicht, ob der Inhalt tatsaechlich
-- unveraendert ist.
function M.verify(path, entry, crc32_fn)
  if not fs.exists(path) then return false, "missing: " .. path end
  local content = M.read(path)
  if not content then return false, "unreadable: " .. path end
  if entry and entry.size_bytes and #content ~= entry.size_bytes then
    return false, string.format("size mismatch %s: got %d expected %d",
      path, #content, entry.size_bytes)
  end
  if entry and entry.hash and entry.hash ~= "" and type(crc32_fn) == "function" then
    local actual = crc32_fn(content)
    if actual:lower() ~= tostring(entry.hash):lower() then
      return false, string.format("hash mismatch %s: got %s expected %s",
        path, actual, entry.hash)
    end
  end
  if path:sub(-4) == ".lua" then
    local loader, lerr = load(content, "=" .. path, "t", {})
    if not loader then return false, "lua syntax: " .. path .. ": " .. tostring(lerr) end
  end
  return true
end

-- GitHub's raw.githubusercontent.com kann kurz nach einem frischen Push
-- noch alten Inhalt an manche Edge-Server ausliefern -- bei einem
-- Size/Hash-Mismatch direkt nach dem Download wird mit kurzer Pause
-- automatisch neu geladen (frischer Cache-Buster-Zeitstempel pro Versuch),
-- statt die gesamte Installation sofort abzubrechen. Nur fuer echte
-- Downloads relevant (item.content-Mismatches sind ein echter Bug).
local VERIFY_MAX_ATTEMPTS = 4
local VERIFY_RETRY_DELAY_S = 2

function M.install(files, install_root, http_mod, ref, progress_fn, crc32_fn)
  local total = #files
  for i, item in ipairs(files) do
    local rel   = item.path
    local entry = item.entry or {}
    local dest  = install_root .. "/" .. rel
    local last_err

    if item.content then
      -- Vorab bereitgestellter Inhalt (kein Netzwerk-Download) -- kein
      -- Retry sinnvoll, ein Mismatch hier ist ein echter Fehler.
      local ok, werr = M.write(dest, item.content)
      if not ok then return false, werr end
      local ok2, verr = M.verify(dest, entry, crc32_fn)
      if not ok2 then return false, verr end
    else
      local success = false
      for attempt = 1, VERIFY_MAX_ATTEMPTS do
        local body, err = http_mod.download_file(rel, ref)
        if not body then
          last_err = "download failed: " .. rel .. " — " .. tostring(err)
        elseif http_mod.is_html(body) then
          last_err = "unexpected HTML for: " .. rel
        else
          local ok, werr = M.write(dest, body)
          if not ok then
            last_err = werr
          else
            local ok2, verr = M.verify(dest, entry, crc32_fn)
            if ok2 then
              success = true
              break
            end
            last_err = verr
          end
        end
        if attempt < VERIFY_MAX_ATTEMPTS then
          if progress_fn then
            progress_fn(i, total, rel .. " (Versuch " .. attempt .. " fehlgeschlagen, erneuter Versuch...)")
          end
          os.sleep(VERIFY_RETRY_DELAY_S)
        end
      end
      if not success then return false, last_err end
    end

    if progress_fn then progress_fn(i, total, rel) end
  end
  return true
end

return M
