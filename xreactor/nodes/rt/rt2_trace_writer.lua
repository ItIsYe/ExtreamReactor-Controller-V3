-- Die Datei-Seite der Regler-Aufzeichnung (Format: nodes/rt/rt2_trace.lua).
--
-- Getrennt vom Format, weil das Format rein bleiben soll. Hier liegt alles,
-- was schiefgehen kann: Platte voll, Verzeichnis fehlt, Datei zu gross.
--
-- Grundsatz: eine Aufzeichnung darf die Regelung NIE stoeren. Deshalb
--   * ist jeder Dateizugriff in pcall gewrappt und schlaegt still fehl,
--   * wird gepuffert und hoechstens im Flush-Takt geschrieben (ein
--     fs.open/close je Regeltakt bei 10 Hz waere Last ohne Nutzen),
--   * gibt es eine harte Obergrenze je Datei mit Rotation, damit eine
--     vergessene Aufzeichnung keine Platte fuellt. Genau das hat in dieser
--     Anlage schon einmal ein Update verhindert.

local M = {}

-- Bewusst NICHT das Log-Verzeichnis des Knotens: das liegt bei dieser
-- Anlage auf der Diskette (/disk/...), und eine CC-Diskette hat 125 KB
-- insgesamt -- geteilt mit allen anderen Logs. Die Aufzeichnung liegt
-- deshalb im Speicher des Rechners selbst, der um Groessenordnungen
-- groesser ist. Wer sie doch auf die Diskette will (bequemer abzuholen),
-- setzt trace.dir in /xreactor_config/rt.lua und sollte max_bytes
-- entsprechend kleiner waehlen.
local DEFAULTS = {
  dir = "/xreactor_logs",
  basename = "rt_trace",
  interval_ms = 2000,       -- Takt- und Reaktorzeile: so oft
  -- Voller Durchgang: JEDE Turbine mit allen Reglerwerten. Zwischen zwei
  -- Durchgaengen schreibt jede VERAENDERTE Turbine sofort ihre Zeile --
  -- vollstaendig im festen Takt, lueckenlos bei Aenderungen.
  --
  -- 50 Turbinen sind je Durchgang rund 5,5 KB. Bei 15 s sind das ~0,4 KB/s
  -- -- mit max_bytes/keep unten ergibt das rund drei Minuten Historie.
  --
  -- Der Takt ist bewusst traege: auf einem Rechner, dem der Platz ausgeht
  -- (diese Anlage meldete 968 Bytes frei), ist die LAENGE der Historie
  -- mehr wert als die Aufloesung des Rundum-Abdrucks. Aufloesung geht
  -- dadurch kaum verloren -- jede VERAENDERTE Turbine schreibt weiterhin
  -- sofort, und genau die Aenderungen sind der Befund.
  full_sweep_ms = 15000,
  -- Die Methodenzeilen (welche Peripherie-Methode gelesen/geschrieben wird)
  -- aendern sich im Betrieb nicht -- sie brauchen keinen 5s-Takt.
  methods_ms = 60000,
  flush_ms = 2000,          -- Datei anfassen: hoechstens so oft
  max_bytes = 32 * 1024,    -- dann rotieren
  keep = 1,                 -- eine Vorgaenger-Datei (also max ~66 KB)
  max_turbine_rows = 12,    -- Aenderungszeilen je Takt (Sturmbremse)
  -- HARTE Freiplatz-Bremse. Unterhalb davon wird NICHTS mehr geschrieben.
  --
  -- Das ist die eigentliche Absicherung, nicht max_bytes: die Installation
  -- belegt allein rund 1,9 MB, und installer/auto_update.lua's
  -- ensure_temp_space() LOESCHT /xreactor_logs komplett, wenn ein Update
  -- Platz braucht. Eine Aufzeichnung, die den letzten freien Platz
  -- verbraucht, verhindert damit genau das Update, mit dem man den Fehler
  -- beheben wollte -- und wird beim Aufraeumen selbst mit weggeworfen.
  --
  -- Der Reservewert liegt deutlich ueber dem, was ein Installer-Download
  -- braucht (#body + 1024), damit die Aufzeichnung nie die Ursache eines
  -- fehlgeschlagenen Updates sein kann.
  min_free_bytes = 256 * 1024,
}

function M.defaults()
  local copy = {}
  for k, v in pairs(DEFAULTS) do copy[k] = v end
  return copy
end

-- opts: siehe DEFAULTS, plus node_id (fuer den Dateinamen) und
-- optional fs_impl/now_ms (Tests).
function M.new(opts)
  opts = opts or {}
  local self = {
    dir = opts.dir or DEFAULTS.dir,
    basename = opts.basename or DEFAULTS.basename,
    interval_ms = tonumber(opts.interval_ms) or DEFAULTS.interval_ms,
    full_sweep_ms = tonumber(opts.full_sweep_ms) or DEFAULTS.full_sweep_ms,
    flush_ms = tonumber(opts.flush_ms) or DEFAULTS.flush_ms,
    max_bytes = tonumber(opts.max_bytes) or DEFAULTS.max_bytes,
    keep = math.max(1, tonumber(opts.keep) or DEFAULTS.keep),
    max_turbine_rows = tonumber(opts.max_turbine_rows) or DEFAULTS.max_turbine_rows,
    methods_ms = tonumber(opts.methods_ms) or DEFAULTS.methods_ms,
    min_free_bytes = tonumber(opts.min_free_bytes) or DEFAULTS.min_free_bytes,
    node_id = opts.node_id,
    fs = opts.fs_impl or _G.fs,
    buffer = {},
    buffered_bytes = 0,
    file_bytes = nil,
    last_sample_ms = nil,
    last_sweep_ms = nil,
    last_methods_ms = nil,
    last_flush_ms = nil,
    memory = { signatures = {} },
    dropped_writes = 0,
    paused_for_space = false,
    space_notices = 0,
  }

  function self.path()
    local name = self.basename
    if self.node_id then name = name .. "_" .. tostring(self.node_id) end
    return self.dir .. "/" .. name .. ".csv"
  end

  function self.rotated_path(index)
    return self.path() .. "." .. tostring(index)
  end

  -- Ist ein Takt aufzeichnungswuerdig? Der Aufrufer darf jeden Takt fragen.
  function self.due(now_ms)
    if not now_ms then return false end
    if not self.last_sample_ms then return true end
    return (now_ms - self.last_sample_ms) >= self.interval_ms
  end

  function self.sweep_due(now_ms)
    if not now_ms then return false end
    if not self.last_sweep_ms then return true end
    return (now_ms - self.last_sweep_ms) >= self.full_sweep_ms
  end

  function self.methods_due(now_ms)
    if not now_ms then return false end
    if not self.last_methods_ms then return true end
    return (now_ms - self.last_methods_ms) >= self.methods_ms
  end

  function self.note_methods(now_ms)
    self.last_methods_ms = now_ms
  end

  local function ensure_dir()
    local fs = self.fs
    if not fs then return false end
    if type(fs.exists) == "function" and fs.exists(self.dir) then return true end
    if type(fs.makeDir) ~= "function" then return false end
    local ok = pcall(fs.makeDir, self.dir)
    return ok
  end

  local function current_size()
    if self.file_bytes then return self.file_bytes end
    local fs = self.fs
    if not fs or type(fs.getSize) ~= "function" or type(fs.exists) ~= "function" then
      self.file_bytes = 0
      return 0
    end
    if not fs.exists(self.path()) then
      self.file_bytes = 0
      return 0
    end
    local ok, size = pcall(fs.getSize, self.path())
    self.file_bytes = (ok and type(size) == "number") and size or 0
    return self.file_bytes
  end

  -- Aelteste weg, die anderen eins weiter, aktuelle auf .1.
  local function rotate()
    local fs = self.fs
    if not fs then return end
    pcall(function()
      local oldest = self.rotated_path(self.keep)
      if type(fs.exists) == "function" and fs.exists(oldest) and type(fs.delete) == "function" then
        fs.delete(oldest)
      end
      for index = self.keep - 1, 1, -1 do
        local from, to = self.rotated_path(index), self.rotated_path(index + 1)
        if type(fs.exists) == "function" and fs.exists(from) and type(fs.move) == "function" then
          fs.move(from, to)
        end
      end
      if type(fs.exists) == "function" and fs.exists(self.path()) and type(fs.move) == "function" then
        fs.move(self.path(), self.rotated_path(1))
      end
    end)
    self.file_bytes = 0
  end

  -- Freier Platz auf dem Datentraeger, oder nil wenn nicht feststellbar.
  local function free_bytes()
    local fs = self.fs
    if not fs or type(fs.getFreeSpace) ~= "function" then return nil end
    local ok, free = pcall(fs.getFreeSpace, self.dir)
    if not ok then
      ok, free = pcall(fs.getFreeSpace, "/")
    end
    if not ok then return nil end
    -- CC:Tweaked liefert fuer unbegrenzte Laufwerke "unlimited".
    if type(free) == "string" then
      if free:lower() == "unlimited" then return math.huge end
      free = tonumber(free)
    end
    if type(free) ~= "number" then return nil end
    return free
  end

  -- Darf ueberhaupt noch geschrieben werden? Sobald es knapp wird, gibt die
  -- Aufzeichnung den Platz frei und haelt an -- sie ist Diagnose, nicht
  -- Betrieb. Sie meldet sich wieder, wenn Platz da ist.
  function self.space_ok()
    local free = free_bytes()
    if free == nil then return true end   -- nicht feststellbar: wie bisher
    if free >= self.min_free_bytes then
      if self.paused_for_space then
        self.paused_for_space = false
        pcall(print, "[RT] Aufzeichnung laeuft wieder (Platz frei)")
      end
      return true
    end
    if not self.paused_for_space then
      self.paused_for_space = true
      self.space_notices = self.space_notices + 1
      -- Auf den Schirm, nicht in den Log-Collector: wer hier nachsieht,
      -- steht vor dem Rechner.
      pcall(print, string.format(
        "[RT] Aufzeichnung ANGEHALTEN -- nur noch %d KB frei (Reserve %d KB)",
        math.floor(free / 1024), math.floor(self.min_free_bytes / 1024)))
      -- Den eigenen Platz sofort hergeben: die Vorgaengerdateien zuerst.
      local fs = self.fs
      if fs and type(fs.delete) == "function" then
        for index = 1, self.keep do
          pcall(function()
            if type(fs.exists) == "function" and fs.exists(self.rotated_path(index)) then
              fs.delete(self.rotated_path(index))
            end
          end)
        end
      end
    end
    return false
  end

  -- Puffer auf die Platte. Rueckgabe: true wenn geschrieben wurde.
  function self.flush(now_ms)
    if #self.buffer == 0 then return false end
    if not self.space_ok() then
      -- Puffer verwerfen, nicht anwachsen lassen: ein wachsender Puffer
      -- verschiebt das Platzproblem nur in den Hauptspeicher.
      self.buffer, self.buffered_bytes = {}, 0
      self.last_flush_ms = now_ms
      return false
    end
    local fs = self.fs
    if not fs or type(fs.open) ~= "function" then
      self.buffer, self.buffered_bytes = {}, 0
      return false
    end
    if not ensure_dir() then
      self.buffer, self.buffered_bytes = {}, 0
      self.dropped_writes = self.dropped_writes + 1
      return false
    end

    if current_size() + self.buffered_bytes > self.max_bytes then
      rotate()
    end

    local fresh = current_size() == 0
    local payload = table.concat(self.buffer, "\n") .. "\n"
    if fresh then
      local rt2_trace = require("nodes.rt.rt2_trace")
      payload = rt2_trace.HEADER .. "\n" .. payload
    end

    local ok = pcall(function()
      local handle = fs.open(self.path(), fresh and "w" or "a")
      if not handle then error("open failed", 0) end
      handle.write(payload)
      handle.close()
    end)
    if ok then
      self.file_bytes = current_size() + #payload
    else
      self.dropped_writes = self.dropped_writes + 1
      self.file_bytes = nil
    end
    self.buffer, self.buffered_bytes = {}, 0
    self.last_flush_ms = now_ms
    return ok
  end

  -- Zeilen anhaengen; schreibt nur, wenn der Flush-Takt erreicht ist.
  function self.append(rows, now_ms)
    for _, row in ipairs(rows or {}) do
      self.buffer[#self.buffer + 1] = row
      self.buffered_bytes = self.buffered_bytes + #row + 1
    end
    self.last_sample_ms = now_ms
    local due = (not self.last_flush_ms) or (now_ms and (now_ms - self.last_flush_ms) >= self.flush_ms)
    -- Nicht unbegrenzt puffern: ein Absturz soll nicht die letzten
    -- Sekunden vor dem Absturz mitnehmen, und die sind die wichtigen.
    if due or self.buffered_bytes >= 4096 then
      return self.flush(now_ms)
    end
    return false
  end

  function self.note_sweep(now_ms)
    self.last_sweep_ms = now_ms
  end

  return self
end

return M
