-- installer/plan_validator.lua
--
-- Vorab-Validierung des Installationsplans. Muss VOR dem ersten
-- destruktiven Schritt (Config-Backup/Loeschen des alten Baums) aufgerufen
-- werden -- ein fehlgeschlagener Guard lehnt die gesamte geplante
-- Installation ab, statt Probleme erst waehrend/nach dem Loeschen zu entdecken.
--
-- Prueft ausschliesslich, was aus Rolle + Manifest + geplanter Dateiliste
-- ohne Netzwerk-Download bekannt ist: erlaubte Rollenwerte, erwarteter
-- Entrypoint der Rolle, doppelte Pfade, absolute Pfade/".."-Traversal,
-- gueltige Hash-/Groessenfelder, Manifest-Selbstkonsistenz sowie maximale
-- Manifest-/Dateigroesse. Transitive require()/dofile()-Abdeckung laesst
-- sich nicht aus dem Plan allein pruefen (Dateiinhalte sind vor dem
-- Download unbekannt) -- das laeuft als eigenstaendiger Testsuite-Check
-- (siehe tests/manifest_transitive_require_coverage_test.lua).

local M = {}

-- Bekannte Rollenwerte und ihr erwarteter Entrypoint -- bewusst dieselbe
-- Zuordnung wie xreactor/start.lua's ROLE_ENTRY (dort nicht als Modul
-- importierbar, start.lua ist ein eigenstaendiges Top-Level-Skript ohne
-- require()-Abhaengigkeiten). tests/manifest_transitive_require_coverage_
-- test.lua haelt beide Listen strukturell synchron.
M.ROLE_ENTRYPOINTS = {
  MASTER        = "master/main.lua",
  RT            = "nodes/rt/main.lua",
  ENERGY        = "nodes/energy/main.lua",
  WATER         = "nodes/water/main.lua",
  FUEL          = "nodes/fuel/main.lua",
  VALVE         = "nodes/valve/main.lua",
  REPROCESSING  = "nodes/reprocessor/main.lua",
  LOG           = "nodes/log_collector/mockup_main.lua",
  LOG_COLLECTOR = "nodes/log_collector/mockup_main.lua",
}

M.MAX_FILE_SIZE_BYTES = 200 * 1024
M.MAX_TOTAL_SIZE_BYTES = 2 * 1024 * 1024
M.MAX_FILE_COUNT = 500

local function is_hex(s, len)
  if type(s) ~= "string" then return false end
  if len and #s ~= len then return false end
  return s:match("^%x+$") ~= nil
end

-- Kein absoluter Pfad, kein ".."-Segment. Installationsplaene bestehen
-- ausschliesslich aus Pfaden relativ zu INSTALL_ROOT ("/xreactor") --
-- ein absoluter Pfad oder eine ".."-Traversal koennte Dateien ausserhalb
-- des vorgesehenen Installationsbaums schreiben.
local function path_is_safe(path)
  if type(path) ~= "string" or path == "" then return false end
  if path:sub(1, 1) == "/" then return false end
  if path:sub(1, 1) == "\\" then return false end
  for segment in (path .. "/"):gmatch("([^/]*)/") do
    if segment == ".." then return false end
  end
  return true
end

-- plan = {
--   role = { key = ..., label = ... },
--   manifest = { manifest_id = ..., manifest_version = ..., ... },
--   files = { [path] = { size_bytes = ..., hash = ..., ... }, ... },
-- }
function M.validate(plan)
  plan = plan or {}
  local role = plan.role
  local manifest = plan.manifest
  local files = plan.files or {}

  if not role or type(role.label) ~= "string" or role.label == "" then
    return false, "Installationsplan ohne gueltige Rolle"
  end
  local entrypoint = M.ROLE_ENTRYPOINTS[role.label:upper()]
  if not entrypoint then
    return false, "unbekannte Rolle im Installationsplan: " .. tostring(role.label)
  end

  local file_count = 0
  local total_size = 0
  local has_entrypoint = false

  for path, entry in pairs(files) do
    file_count = file_count + 1
    if file_count > M.MAX_FILE_COUNT then
      return false, "Installationsplan zu gross: mehr als " .. M.MAX_FILE_COUNT .. " Dateien"
    end

    if not path_is_safe(path) then
      return false, "unsicherer Pfad im Installationsplan: " .. tostring(path)
    end

    entry = entry or {}
    -- Fix: Eintraege ohne hash (z.B. manifest.lua, release.lua, start.lua
    -- die vom Installer selbst hinzugefuegt werden) haben kein size_bytes --
    -- diese Eintraege werden nur heruntergeladen, nicht gegen Hash geprueft.
    local has_hash = type(entry.hash) == "string" and entry.hash ~= ""
    local size = tonumber(entry.size_bytes)
    if has_hash and (size == nil or size < 0) then
      return false, "ungueltiges size_bytes-Feld fuer: " .. path
    end
    size = size or 0
    if size > M.MAX_FILE_SIZE_BYTES then
      return false, "Datei zu gross (" .. size .. " Bytes, max " .. M.MAX_FILE_SIZE_BYTES .. "): " .. path
    end
    total_size = total_size + size

    -- Manche Eintraege (z.B. lokal generierte optional_features.lua/
    -- role.lua-Inhalte, nicht Manifest-Downloads) haben absichtlich kein
    -- hash-Feld -- nur pruefen, wenn eines gesetzt ist (nicht nil, nicht
    -- leerer String).
    if entry.hash ~= nil and entry.hash ~= "" and not is_hex(entry.hash, 8) then
      return false, "ungueltiges hash-Feld (CRC32, 8 Hex-Zeichen erwartet) fuer: " .. path .. " (" .. tostring(entry.hash) .. ")"
    end

    if path == entrypoint then has_entrypoint = true end
  end

  if not has_entrypoint then
    return false, "erwarteter Entrypoint fuer Rolle " .. role.label .. " fehlt im Installationsplan: " .. entrypoint
  end

  if total_size > M.MAX_TOTAL_SIZE_BYTES then
    return false, "Installationsplan insgesamt zu gross: " .. total_size .. " Bytes (max " .. M.MAX_TOTAL_SIZE_BYTES .. ")"
  end

  if manifest ~= nil then
    local mid = manifest.manifest_id
    local mv = manifest.manifest_version
    if type(mid) ~= "string" or mid == "" then
      return false, "Manifest-Metadaten unvollstaendig: manifest_id fehlt"
    end
    if type(mv) ~= "number" then
      return false, "Manifest-Metadaten unvollstaendig: manifest_version fehlt"
    end
    if not mid:find(tostring(mv), 1, true) then
      return false, "Manifest-Inkonsistenz: manifest_id (" .. mid .. ") passt nicht zu manifest_version (" .. tostring(mv) .. ")"
    end
  end

  return true
end

return M
