-- tests/installer_stage_write_backup_failure_test.lua
--
-- Regression test fuer INSTALL-P0.3 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 5): installer/stage.lua's M.write()
-- loeschte frueher die ALTE Datei als "letzter Ausweg", wenn der Backup-Move
-- (path -> path.xr_prev) fehlschlug, und lief dann einfach weiter -- schlug
-- danach auch noch der finale tmp->path Move fehl, war die alte Datei
-- unwiderruflich weg UND kein Backup vorhanden, um sie zurueckzuholen.
-- Jetzt muss M.write() bei einem fehlgeschlagenen Backup-Move SOFORT
-- abbrechen, OHNE die alte Datei anzutasten.

local files = {}
local move_attempts = {}

_G.fs = {
  getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
  exists = function(p) return files[p] ~= nil end,
  makeDir = function() end,
  getFreeSpace = function() return 1024 * 1024 * 1024 end,
  open = function(p, mode)
    if mode == "w" then
      local buf = {}
      return {
        write = function(content) buf[#buf + 1] = content end,
        close = function() files[p] = table.concat(buf) end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      return {
        readAll = function() return files[p] end,
        close = function() end,
      }
    end
    return nil
  end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst)
    move_attempts[#move_attempts + 1] = { src = src, dst = dst }
    if dst:sub(-8) == ".xr_prev" then
      error("simulated backup move failure: no space left")
    end
    files[dst] = files[src]
    files[src] = nil
  end,
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
local stage = require("installer.stage")

local TARGET = "/xreactor/config/role.lua"
files[TARGET] = "return { role = \"FUEL-NODE\" }\n"

local ok, err = stage.write(TARGET, "return { role = \"WATER-NODE\" }\n")

if ok then
  error("expected write to fail when the backup move fails, got ok=true")
end
if not tostring(err):find("backup move failed", 1, true) then
  error("expected 'backup move failed' in error, got: " .. tostring(err))
end
if not fs.exists(TARGET) then
  error("CRITICAL: old file was deleted despite failed backup — data loss")
end
if files[TARGET] ~= "return { role = \"FUEL-NODE\" }\n" then
  error("old file content was modified despite failed backup")
end
if files[TARGET .. ".xr_tmp"] ~= nil then
  error("leftover .xr_tmp was not cleaned up after aborted write")
end
if files[TARGET .. ".xr_prev"] ~= nil then
  error("backup file should not exist after a failed backup move")
end

-- Sanity: normal writes (no simulated failure) must still work end-to-end.
local files2 = {}
_G.fs.exists = function(p) return files2[p] ~= nil end
_G.fs.open = function(p, mode)
  if mode == "w" then
    local buf = {}
    return {
      write = function(content) buf[#buf + 1] = content end,
      close = function() files2[p] = table.concat(buf) end,
    }
  elseif mode == "r" then
    if not files2[p] then return nil end
    return { readAll = function() return files2[p] end, close = function() end }
  end
  return nil
end
_G.fs.delete = function(p) files2[p] = nil end
_G.fs.move = function(src, dst)
  files2[dst] = files2[src]
  files2[src] = nil
end
files2[TARGET] = "old"
local ok2, err2 = stage.write(TARGET, "new")
if not ok2 then error("expected normal write to succeed, got err: " .. tostring(err2)) end
if files2[TARGET] ~= "new" then error("normal write did not persist new content") end
if files2[TARGET .. ".xr_prev"] ~= nil then error("backup should be cleaned up after a successful write") end

print("installer_stage_write_backup_failure_test.lua: ok")
