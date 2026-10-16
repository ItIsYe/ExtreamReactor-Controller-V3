-- core/install_integrity.lua
-- Prueft die installierten Dateien gegen ihre Pruefsummen.
--
-- Betreiberentscheidung (2026-10-08): "fuer Dateien Pruefsumme, um
-- festzustellen, wie alt sie sind und ob sie ueberhaupt noch relevant sind
-- bzw. noch genommen werden duerfen". Der Installer schreibt bei jeder
-- Installation /xreactor/install_hashes.lua: Fassung, Inhalts-Pruefsumme
-- der Fassung (payload_digest) und je installierter Datei Groesse und CRC32
-- aus dem Manifest. check() liest jede Datei und vergleicht. Weicht eine ab
-- (veraendert, abgeschnitten) oder fehlt sie, gehoert sie nicht mehr zu der
-- Fassung, die der Knoten zu haben glaubt -- installer/auto_update.lua
-- installiert dann neu (decide_repair() unten begrenzt das).
--
-- Gelesen wird genau wie installer/stage.lua's verify() (fs.open "r",
-- readAll) und mit derselben CRC32 wie installer/manifest.lua -- sonst
-- meldete die Pruefung Abweichungen, die die Installation selbst nicht
-- sieht, und der Knoten installierte immer wieder neu.
--
-- Bewusst eigenstaendig (nur CC-APIs): der Auto-Updater laedt es per
-- dofile(), auf jeder Rolle, auch LOG.

local M = {}

M.INSTALL_ROOT = "/xreactor"
M.HASHES_PATH = "/xreactor/install_hashes.lua"

-- Dieselbe Tabelle und dieselbe Yield-Strategie wie installer/manifest.lua.
local CRC_TABLE = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit32.band(c, 1) == 1 then
      c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
    else
      c = bit32.rshift(c, 1)
    end
  end
  CRC_TABLE[i] = c
end

local CRC_YIELD_EVERY = 512
local CRC_YIELD_EVENT = "__xr_crc32_yield"

function M.crc32(content)
  local can_yield = type(os) == "table"
    and type(os.queueEvent) == "function" and type(os.pullEvent) == "function"
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    local idx = bit32.band(bit32.bxor(crc, string.byte(content, i)), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), CRC_TABLE[idx])
    if can_yield and i % CRC_YIELD_EVERY == 0 then
      os.queueEvent(CRC_YIELD_EVENT)
      os.pullEvent(CRC_YIELD_EVENT)
    end
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end

local function read_all(path)
  local ok, handle = pcall(fs.open, path, "r")
  if not ok or not handle then return nil end
  local ok_read, content = pcall(handle.readAll)
  pcall(handle.close)
  if not ok_read then return nil end
  return content
end

-- Die Pruefsummenliste, oder nil und ein Grund.
function M.load_hashes(path)
  path = path or M.HASHES_PATH
  if not fs.exists(path) then return nil, "keine Pruefsummenliste" end
  local content = read_all(path)
  if not content then return nil, "Pruefsummenliste nicht lesbar" end
  local chunk = load(content, "=install_hashes", "t", {})
  if not chunk then return nil, "Pruefsummenliste ungueltig" end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    return nil, "Pruefsummenliste ungueltig"
  end
  return data
end

-- Prueft jede verzeichnete Datei. Ergebnis:
--   ok        true: alle passen | false: mindestens eine weicht ab |
--             nil: keine Pruefsummenliste (z. B. vor v814 installiert)
--   checked, missing = { pfad... }, changed = { pfad... }
--   manifest_id, manifest_version, payload_digest   der installierten Fassung
--   reason    nur bei ok == nil
function M.check(opts)
  opts = opts or {}
  local hashes, err = M.load_hashes(opts.hashes_path)
  if not hashes then return { ok = nil, reason = err, checked = 0, missing = {}, changed = {} } end
  local root = opts.root or M.INSTALL_ROOT
  local result = {
    ok = true, checked = 0, missing = {}, changed = {},
    manifest_id = hashes.manifest_id, manifest_version = hashes.manifest_version,
    payload_digest = hashes.payload_digest,
  }
  local paths = {}
  for rel in pairs(hashes.files) do paths[#paths + 1] = rel end
  table.sort(paths)
  for _, rel in ipairs(paths) do
    local entry = hashes.files[rel]
    local full = root .. "/" .. rel
    local content = fs.exists(full) and read_all(full) or nil
    if not content then
      result.missing[#result.missing + 1] = rel
    elseif type(entry) == "table" and tonumber(entry.size) and #content ~= tonumber(entry.size) then
      result.changed[#result.changed + 1] = rel
    elseif type(entry) == "table" and type(entry.hash) == "string" and entry.hash ~= ""
        and M.crc32(content) ~= entry.hash:lower() then
      result.changed[#result.changed + 1] = rel
    end
    result.checked = result.checked + 1
  end
  result.ok = #result.missing == 0 and #result.changed == 0
  return result
end

-- Eine Zeile fuer Terminal und Statusdatei.
function M.describe(result)
  if type(result) ~= "table" then return "Dateipruefung: kein Ergebnis" end
  if result.ok == nil then return "Dateipruefung: " .. tostring(result.reason or "nicht moeglich") end
  local label = tostring(result.manifest_id or "?")
  if result.payload_digest and result.payload_digest ~= "" then
    label = label .. " / Pruefsumme " .. tostring(result.payload_digest)
  end
  if result.ok then
    return string.format("Dateipruefung ok: %d Dateien passen zu %s", result.checked, label)
  end
  local names = {}
  for _, rel in ipairs(result.missing) do names[#names + 1] = rel .. " (fehlt)" end
  for _, rel in ipairs(result.changed) do names[#names + 1] = rel .. " (veraendert)" end
  local shown = {}
  for i = 1, math.min(3, #names) do shown[i] = names[i] end
  if #names > 3 then shown[#shown + 1] = "+" .. tostring(#names - 3) .. " weitere" end
  return string.format("Dateipruefung: %d von %d Dateien passen NICHT zu %s: %s",
    #names, result.checked, label, table.concat(shown, ", "))
end

-- Darf jetzt neu installiert werden? Hoechstens einmal je installierter
-- Fassung (payload_digest bzw. manifest_id) innerhalb von cooldown_s --
-- sonst stuende ein Knoten, dessen Abweichung eine Neuinstallation nicht
-- behebt, in einer Schleife aus Quiesce, Installation und Neustart.
--   state   der zuletzt gespeicherte Versuch ({ key, at_ms }) oder nil
-- Liefert allowed und den neuen Zustand zum Speichern (nur wenn allowed).
function M.decide_repair(result, state, now_ms, cooldown_s)
  if type(result) ~= "table" or result.ok ~= false then return false, nil end
  local key = tostring(result.payload_digest ~= "" and result.payload_digest or result.manifest_id or "?")
  now_ms = tonumber(now_ms) or 0
  local cooldown_ms = (tonumber(cooldown_s) or 0) * 1000
  if type(state) == "table" and state.key == key and tonumber(state.at_ms)
      and now_ms - tonumber(state.at_ms) < cooldown_ms and now_ms >= tonumber(state.at_ms) then
    return false, nil
  end
  return true, { key = key, at_ms = now_ms }
end

return M
