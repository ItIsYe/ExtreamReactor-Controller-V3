-- installer/journal.lua
--
-- Transaktionales Installationsjournal (INSTALL-P0.1, siehe docs/CODING_AI_
-- OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 3). Lebt AUSSERHALB des
-- ersetzten Baums (/xreactor), damit ein abgebrochener Installationslauf
-- auch dann noch belegt werden kann, wenn /xreactor selbst geloescht oder
-- nur teilweise neu geschrieben wurde. Der Installer schreibt das Journal
-- als ERSTES (PREPARED, vor dem Loeschen des alten Baums) und aktualisiert
-- es entlang der Stationen INSTALLING -> VERIFYING -> COMMITTED; COMMITTED
-- wird zusammen mit release.lua als LETZTER Schritt des gesamten Laufs
-- geschrieben (siehe installer/init.lua und /installer). xreactor/start.lua
-- prueft dieses Journal bei JEDEM Boot, bevor die eigentliche Rolle
-- gestartet wird.

local M = {}

M.PATH = "/xreactor_install_journal.lua"

M.STATE = {
  PREPARED   = "PREPARED",
  INSTALLING = "INSTALLING",
  VERIFYING  = "VERIFYING",
  COMMITTED  = "COMMITTED",
}

-- Eigener, von installer/stage.lua UNABHAENGIGER atomarer Write: journal.lua
-- wird auch von xreactor/start.lua bei JEDEM Boot gelesen, potenziell bevor
-- der Rest von /xreactor in einem verlaesslichen Zustand ist -- keine
-- Abhaengigkeit auf stage.lua's reclaim()/WRITE_BUFFER-Logik hier, nur ein
-- minimaler tmp-write-plus-move.
local function atomic_write(path, content)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "open failed: " .. tmp end
  local write_ok, write_err = pcall(function() f.write(content) end)
  pcall(f.close)
  if not write_ok then
    pcall(fs.delete, tmp)
    return false, tostring(write_err)
  end
  if fs.exists(path) then pcall(fs.delete, path) end
  local ok, mv_err = pcall(fs.move, tmp, path)
  if not ok or not fs.exists(path) then
    pcall(fs.delete, tmp)
    return false, "move failed: " .. tostring(mv_err)
  end
  return true
end

local function serialize_string_array(list)
  local parts = {}
  for _, item in ipairs(list) do
    parts[#parts + 1] = string.format("%q", tostring(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Erwartet ein flaches Journal: state/ref/manifest_id/role sind Strings,
-- expected_files eine Liste von Pfaden, started_at eine Zahl. Kein
-- generischer Serializer -- das Journal braucht keine tieferen Strukturen.
local function serialize(journal)
  local parts = { "return {\n" }
  parts[#parts + 1] = "  state = " .. string.format("%q", tostring(journal.state)) .. ",\n"
  parts[#parts + 1] = "  ref = " .. string.format("%q", tostring(journal.ref)) .. ",\n"
  parts[#parts + 1] = "  manifest_id = " .. string.format("%q", tostring(journal.manifest_id)) .. ",\n"
  parts[#parts + 1] = "  role = " .. string.format("%q", tostring(journal.role)) .. ",\n"
  parts[#parts + 1] = "  started_at = " .. tostring(tonumber(journal.started_at) or 0) .. ",\n"
  parts[#parts + 1] = "  expected_files = " .. serialize_string_array(journal.expected_files or {}) .. ",\n"
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

function M.write(journal)
  return atomic_write(M.PATH, serialize(journal))
end

function M.read()
  if not fs.exists(M.PATH) then return nil end
  local f = fs.open(M.PATH, "r")
  if not f then return nil end
  local src = f.readAll()
  f.close()
  local loader = load(src, "=install_journal", "t", {})
  if not loader then return nil end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" or type(result.state) ~= "string" then return nil end
  return result
end

function M.clear()
  if fs.exists(M.PATH) then pcall(fs.delete, M.PATH) end
end

-- Bootzeit-Klassifikation: liefert nil, wenn kein Journal vorhanden ist
-- (Normalfall) oder wenn der letzte Lauf COMMITTED war (Journal wird direkt
-- nach dem Commit geloescht -- dieser Fall tritt praktisch nur bei einem
-- Crash GENAU zwischen COMMITTED-Schreiben und Clear auf, was ebenfalls
-- unbedenklich ist: die Installation war zu diesem Zeitpunkt bereits
-- vollstaendig und verifiziert). In jedem anderen Fall (PREPARED/
-- INSTALLING/VERIFYING) war der letzte Lauf nachweislich unvollstaendig.
function M.check_incomplete()
  local journal = M.read()
  if not journal then return nil end
  if journal.state == M.STATE.COMMITTED then return nil end
  return journal
end

return M
