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
  interval_ms = 2000,       -- Sammelzeile: so oft
  full_sweep_ms = 60000,    -- voller Turbinen-Durchgang: so oft
  flush_ms = 2000,          -- Datei anfassen: hoechstens so oft
  max_bytes = 64 * 1024,    -- dann rotieren
  keep = 3,                 -- so viele Dateien behalten (also max 192 KB)
  max_turbine_rows = 12,    -- aenderungsgetriebene Zeilen je Takt
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
    node_id = opts.node_id,
    fs = opts.fs_impl or _G.fs,
    buffer = {},
    buffered_bytes = 0,
    file_bytes = nil,
    last_sample_ms = nil,
    last_sweep_ms = nil,
    last_flush_ms = nil,
    memory = { signatures = {} },
    dropped_writes = 0,
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

  -- Puffer auf die Platte. Rueckgabe: true wenn geschrieben wurde.
  function self.flush(now_ms)
    if #self.buffer == 0 then return false end
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
