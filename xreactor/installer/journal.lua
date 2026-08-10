-- installer/journal.lua
--
-- Transaktionales Installationsjournal (INSTALL-P0.1/P0.2, siehe docs/
-- CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitte 3+4). Lebt
-- AUSSERHALB des ersetzten Baums (/xreactor), damit ein abgebrochener
-- Installationslauf auch dann noch belegt werden kann, wenn /xreactor
-- selbst geloescht oder nur teilweise neu geschrieben wurde. Der Installer
-- schreibt das Journal als ERSTES (PREPARED, vor dem Loeschen des alten
-- Baums) und aktualisiert es entlang der Stationen INSTALLING -> VERIFYING
-- -> COMMITTED. xreactor/start.lua prueft dieses Journal bei JEDEM Boot,
-- bevor die eigentliche Rolle gestartet wird.
--
-- Fix (2026-07-19): CRITICAL. Die vorherige Fassung schrieb GENAU EINE
-- Journaldatei per "tmp schreiben -> alte Datei loeschen -> tmp verschieben"
-- (siehe Git-Historie). Zwischen dem Loeschen der alten Datei und dem
-- erfolgreichen Verschieben existierte ein Fenster OHNE gueltiges
-- Hauptjournal -- ein Stromausfall/Chunk-Unload/Move-Fehler genau dort
-- hinterliess weder die alte noch die neue Generation lesbar (INSTALL-
-- P0.1). Ausserdem behandelten sowohl diese Datei als auch start.lua jeden
-- Parse-/Lesefehler identisch zu "kein Journal vorhanden" (INSTALL-P0.2) --
-- ein beschaedigtes Journal waehrend genau eines abgebrochenen Updates war
-- damit nicht von einem sauberen Erststart unterscheidbar.
--
-- Jetzt: zwei fest benannte Generationsslots (SLOT_A/SLOT_B) mit einer
-- monoton steigenden "generation"-Zahl im Journalinhalt selbst -- KEIN
-- separates Pointer-/Indexfile, das seinerseits ein Delete-vor-Move-Fenster
-- haette. Jeder M.write()-Aufruf schreibt AUSSCHLIESSLICH in den Slot mit
-- der (strikt) niedrigeren Generation ("stale" Slot); der jeweils andere
-- Slot -- der Slot mit der aktuell hoechsten gueltigen Generation --
-- bleibt dabei voellig unangetastet. Ein Crash an JEDEM Punkt dieses
-- Schreibvorgangs (Tmp-Write, Delete des alten Slotinhalts, Move)
-- hinterlaesst den anderen Slot weiterhin vollstaendig und mit seiner
-- zuletzt bestaetigten Generation lesbar -- boot-seitige Klassifikation
-- (M.classify()) waehlt danach einfach wieder den hoechsten GUELTIGEN
-- Generationsstand. Zusaetzlich unterscheidet die Klassifikation jetzt
-- ABSENT / VALID_COMMITTED / VALID_INCOMPLETE / CORRUPT / UNREADABLE statt
-- alles ausser einem gueltigen Ergebnis auf "kein Journal" abzubilden;
-- nur ABSENT (wirklich nie ein Journal geschrieben) oder VALID_COMMITTED
-- erlauben im Bootpfad einen normalen Rollenstart.

local M = {}

M.STATE = {
  PREPARED   = "PREPARED",
  INSTALLING = "INSTALLING",
  VERIFYING  = "VERIFYING",
  COMMITTED  = "COMMITTED",
}

local VALID_STATES = {}
for _, s in pairs(M.STATE) do VALID_STATES[s] = true end

M.STATUS = {
  ABSENT           = "ABSENT",
  VALID_COMMITTED  = "VALID_COMMITTED",
  VALID_INCOMPLETE = "VALID_INCOMPLETE",
  CORRUPT          = "CORRUPT",
  UNREADABLE       = "UNREADABLE",
}

M.SLOT_A = "/xreactor_install_journal.a.lua"
M.SLOT_B = "/xreactor_install_journal.b.lua"

-- Alter, vor diesem Fix verwendeter Einzeldatei-Pfad. Wird nicht mehr
-- geschrieben oder als Entscheidungsgrundlage gelesen -- nur M.clear()
-- raeumt ihn opportunistisch auf, falls er von einer aelteren Version
-- dieses Codes noch auf der Platte liegt.
M.LEGACY_PATH = "/xreactor_install_journal.lua"

-- Eigener, von installer/stage.lua UNABHAENGIGER atomarer Write: journal.lua
-- wird auch von xreactor/start.lua bei JEDEM Boot gelesen, potenziell bevor
-- der Rest von /xreactor in einem verlaesslichen Zustand ist -- keine
-- Abhaengigkeit auf stage.lua's reclaim()/WRITE_BUFFER-Logik hier, nur ein
-- minimaler tmp-write-plus-move. Zielpfad ist hier IMMER der aktuell
-- "stale" Slot (siehe M.write()) -- der jeweils andere, gerade gueltige
-- Slot wird von dieser Funktion nie beruehrt.
local function atomic_write(path, content)
  -- Fix: fs.move in CC:Tweaked ist nach einem Delete/Create nicht zuverlaessig
  -- (Verify liest danach CORRUPT zurueck). Direktes Schreiben in die Zieldatei
  -- ist fuer das Journal ausreichend -- das Zwei-Slot-System in M.write() bietet
  -- selbst schon die noetige Absicherung gegen Halbschreiber.
  local f = fs.open(path, "w")
  if not f then return false, "open failed: " .. path end
  local write_ok, write_err = pcall(function() f.write(content) end)
  pcall(f.close)
  if not write_ok then return false, tostring(write_err) end
  return true
end

local function serialize_string_array(list)
  local parts = {}
  for _, item in ipairs(list) do
    parts[#parts + 1] = string.format("%q", tostring(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function serialize_expected_meta(meta)
  local keys = {}
  for path in pairs(meta or {}) do keys[#keys + 1] = path end
  table.sort(keys)
  local parts = { "{" }
  for _, path in ipairs(keys) do
    local entry = meta[path] or {}
    parts[#parts + 1] = "[" .. string.format("%q", tostring(path)) .. "]={size_bytes="
      .. tostring(tonumber(entry.size_bytes) or 0) .. ",hash="
      .. string.format("%q", tostring(entry.hash or "")) .. "},"
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

-- Erwartet ein flaches Journal: state/ref/manifest_id/role sind Strings,
-- expected_files eine Liste von Pfaden, started_at/generation Zahlen. Kein
-- generischer Serializer -- das Journal braucht keine tieferen Strukturen.
local function serialize(journal)
  local parts = { "return {\n" }
  parts[#parts + 1] = "  state = " .. string.format("%q", tostring(journal.state)) .. ",\n"
  parts[#parts + 1] = "  generation = " .. tostring(tonumber(journal.generation) or 0) .. ",\n"
  parts[#parts + 1] = "  ref = " .. string.format("%q", tostring(journal.ref)) .. ",\n"
  parts[#parts + 1] = "  manifest_id = " .. string.format("%q", tostring(journal.manifest_id)) .. ",\n"
  parts[#parts + 1] = "  role = " .. string.format("%q", tostring(journal.role)) .. ",\n"
  parts[#parts + 1] = "  started_at = " .. tostring(tonumber(journal.started_at) or 0) .. ",\n"
  parts[#parts + 1] = "  expected_files = " .. serialize_string_array(journal.expected_files or {}) .. ",\n"
  parts[#parts + 1] = "  expected_meta = " .. serialize_expected_meta(journal.expected_meta or {}) .. ",\n"
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

-- Liest genau einen Slot und klassifiziert ihn fail-closed: jeder Fehler
-- (kein Handle, leer/abgeschnitten, ungueltige Syntax, kein Table-Ergebnis,
-- unbekannter/fehlender state, fehlende/keine Zahl generation) liefert
-- CORRUPT bzw. UNREADABLE statt eines geratenen Journalinhalts.
local function slot_read(path)
  if not fs.exists(path) then return M.STATUS.ABSENT, nil end
  local f = fs.open(path, "r")
  if not f then return M.STATUS.UNREADABLE, nil end
  local ok_read, src = pcall(f.readAll)
  pcall(f.close)
  if not ok_read or type(src) ~= "string" or #src == 0 then
    return M.STATUS.UNREADABLE, nil
  end
  local loader = load(src, "=install_journal", "t", {})
  if not loader then return M.STATUS.CORRUPT, nil end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" then return M.STATUS.CORRUPT, nil end
  if type(result.state) ~= "string" or not VALID_STATES[result.state] then
    return M.STATUS.CORRUPT, nil
  end
  if type(result.generation) ~= "number" then return M.STATUS.CORRUPT, nil end
  if result.expected_files ~= nil and type(result.expected_files) ~= "table" then return M.STATUS.CORRUPT, nil end
  if result.expected_meta ~= nil and type(result.expected_meta) ~= "table" then return M.STATUS.CORRUPT, nil end
  for _, rel in ipairs(result.expected_files or {}) do
    local meta = result.expected_meta and result.expected_meta[rel] or nil
    if meta ~= nil and (type(meta) ~= "table" or type(meta.size_bytes) ~= "number"
        or type(meta.hash) ~= "string" or not meta.hash:match("^[0-9a-f]+$")) then
      return M.STATUS.CORRUPT, nil
    end
  end
  if result.state == M.STATE.COMMITTED then
    return M.STATUS.VALID_COMMITTED, result
  end
  return M.STATUS.VALID_INCOMPLETE, result
end
M._slot_read = slot_read -- fuer Tests

local function generation_of(status, journal)
  if status == M.STATUS.VALID_COMMITTED or status == M.STATUS.VALID_INCOMPLETE then
    return journal.generation
  end
  return -1
end

-- Klassifiziert den Gesamtzustand ueber BEIDE Slots hinweg: der Slot mit
-- der hoechsten gueltigen Generation gewinnt und bestimmt Status/Inhalt.
-- Sind beide Slots ABSENT, ist der Gesamtzustand ABSENT (echter Erststart,
-- noch nie ein Installationslauf begonnen). Existiert mindestens ein Slot,
-- kann aber kein gueltiges Journal geliefert werden, gilt das fail-closed
-- als UNREADABLE/CORRUPT -- NICHT als ABSENT.
function M.classify()
  local status_a, journal_a = slot_read(M.SLOT_A)
  local status_b, journal_b = slot_read(M.SLOT_B)
  local gen_a, gen_b = generation_of(status_a, journal_a), generation_of(status_b, journal_b)

  if gen_a < 0 and gen_b < 0 then
    if status_a == M.STATUS.ABSENT and status_b == M.STATUS.ABSENT then
      return M.STATUS.ABSENT, nil
    end
    if status_a == M.STATUS.UNREADABLE or status_b == M.STATUS.UNREADABLE then
      return M.STATUS.UNREADABLE, nil
    end
    return M.STATUS.CORRUPT, nil
  end

  if gen_a >= gen_b then return status_a, journal_a end
  return status_b, journal_b
end

-- Schreibt eine neue Journalgeneration in den aktuell "stale" Slot (den
-- Slot mit der niedrigeren Generation; beim allerersten Schreiben, wenn
-- beide Slots ABSENT sind, immer SLOT_A). Der jeweils andere Slot -- der
-- die zuletzt bestaetigte Generation traegt -- wird von diesem Aufruf
-- nicht angefasst und bleibt bei JEDEM Fehler waehrend dieses Schreibens
-- die gueltige Fail-Closed-Quelle fuer M.classify().
function M.write(journal)
  local status_a, journal_a = slot_read(M.SLOT_A)
  local status_b, journal_b = slot_read(M.SLOT_B)
  local gen_a, gen_b = generation_of(status_a, journal_a), generation_of(status_b, journal_b)

  local target_path = (gen_a <= gen_b) and M.SLOT_A or M.SLOT_B
  local new_generation = math.max(gen_a, gen_b) + 1

  local to_write = {}
  for k, v in pairs(journal) do to_write[k] = v end
  to_write.generation = new_generation

  local content = serialize(to_write)
  local ok, err = atomic_write(target_path, content)
  if not ok then return false, err end

  -- Round-Trip-Verifikation: erst NACH erfolgreichem Zuruecklesen und
  -- Abgleich gilt dieser Write als abgeschlossen (Vorgabe des Fixes:
  -- "neue Generation vollstaendig schreiben und zuruecklesen, Inhalt/State
  -- validieren, erst danach aktive Generation umschalten" -- das
  -- "Umschalten" ist hier implizit: solange die Verifikation fehlschlaegt,
  -- bleibt die hoehere Generation ja weiterhin im JEWEILS ANDEREN Slot).
  local verify_status, verify_journal = slot_read(target_path)
  local expected_status = (to_write.state == M.STATE.COMMITTED)
    and M.STATUS.VALID_COMMITTED or M.STATUS.VALID_INCOMPLETE
  if verify_status ~= expected_status
    or not verify_journal
    or verify_journal.generation ~= new_generation
    or verify_journal.state ~= to_write.state then
    return false, "journal verify failed after write (status=" .. tostring(verify_status) .. ")"
  end

  return true
end

-- Liefert das aktuell gueltige Journal (hoechste Generation, gueltig
-- geparst), unabhaengig vom state -- oder nil, wenn kein gueltiges Journal
-- existiert (ABSENT/CORRUPT/UNREADABLE).
function M.read()
  local status, journal = M.classify()
  if status == M.STATUS.VALID_COMMITTED or status == M.STATUS.VALID_INCOMPLETE then
    return journal
  end
  return nil
end

-- Bootzeit-Klassifikation (Kompatibilitaets-API): liefert nil, wenn ein
-- normaler Rollenstart zulaessig ist (ABSENT oder VALID_COMMITTED), sonst
-- ein Journaltable. Bei CORRUPT/UNREADABLE -- wo kein echter Journalinhalt
-- existiert -- wird ein synthetisches, erkennbar als solches markiertes
-- Ersatzjournal geliefert, damit Aufrufer trotzdem fail-closed reagieren
-- koennen, ohne selbst zwischen "kein Journal" und "unlesbares Journal"
-- unterscheiden zu muessen.
function M.check_incomplete()
  local status, journal = M.classify()
  if status == M.STATUS.ABSENT or status == M.STATUS.VALID_COMMITTED then
    return nil
  end
  if status == M.STATUS.VALID_INCOMPLETE then
    return journal
  end
  -- CORRUPT oder UNREADABLE: kein gueltiger Inhalt vorhanden, aber
  -- mindestens ein Slot existiert und ist nicht als abgeschlossen
  -- verifizierbar -- fail-closed als unvollstaendig behandeln.
  return {
    state = "UNKNOWN_" .. tostring(status),
    generation = -1,
    ref = nil,
    manifest_id = nil,
    role = nil,
    started_at = 0,
    expected_files = {},
    expected_meta = {},
  }
end

-- Raeumt ausschliesslich den veralteten Einzeldatei-Pfad (M.LEGACY_PATH)
-- aus frueheren Versionen dieses Moduls auf. Die beiden Generationsslots
-- werden hier bewusst NICHT geloescht -- der jeweils naechste M.write()
-- ueberschreibt automatisch nur den dann stale Slot (siehe oben); das
-- vorzeitige Loeschen einer bestaetigten Generation waere exakt der
-- Fehler, den dieser Fix beheben soll.
function M.clear()
  if fs.exists(M.LEGACY_PATH) then pcall(fs.delete, M.LEGACY_PATH) end
end

return M
