-- xreactor/optional/ampel.lua
--
-- Optionale Peripherie: Ampel-Statusmonitor (1x1 oder 1x3 Bloecke).
--
-- Zweck: ein zweiter, kleiner Monitor -- 1 Block breit und 1 oder 3 Bloecke
-- hoch -- wird automatisch erkannt (kein Config-Eintrag noetig) und mit
-- einer einzigen Vollflaechenfarbe je nach Status gefuellt -- kein Text,
-- von weitem als Ampel lesbar.
--
-- Wird von nodes/rt/monitor_ui.lua, nodes/energy/ui_pages.lua und
-- nodes/fuel/monitor_ui.lua genutzt.
--
-- Selbstheilung (v829): bis v828 wurde nur bei einem Farbwechsel gemalt.
-- Verlor der Monitor seinen Inhalt (Chunk neu geladen, Skala von anderer
-- Stelle umgestellt, Monitor neu gebaut), blieb die Ampel schwarz, bis sich
-- der Status aenderte -- bei einer ruhig laufenden Anlage also dauerhaft.
-- Jetzt wird spaetestens alle REPAINT_S Sekunden neu gemalt, und eine
-- verschwundene Ampel wird sofort wieder gesucht.
--
-- Design-Prinzip (gilt fuer alle Module in xreactor/optional/): jede
-- Funktion ist selbst vollstaendig pcall-isoliert. Ein Fehler in einem
-- optionalen Feature darf NIEMALS die Kernfunktion (Reaktorsteuerung,
-- Master-UI, etc.) beeinflussen koennen.

local M = {}

-- Muessen die echten colors-API-Bitmask-Konstanten sein (Zweierpotenzen:
-- colors.white=1, colors.red=16384, ...), keine rohen RGB-Hex-Werte --
-- mon.setBackgroundColor() wirft sonst einen Fehler.
M.COLORS = {
  OK        = colors.green,
  LIMITED   = colors.yellow,
  WARNING   = colors.orange,
  EMERGENCY = colors.red,
  muted     = colors.gray,
}

-- Spaetestens so oft wird die Farbe neu gemalt, auch ohne Statuswechsel.
M.REPAINT_S = 10
-- So oft wird nach einer Ampel gesucht, solange keine gefunden ist.
M.PROBE_S = 30

-- Ampel-Form bei Skala 1 -- dieselbe Regel lehnt solche Monitore in
-- adapters/monitor.lua als Hauptmonitor ab. Geometrie (CC:Tweaked): ein
-- Block = 7x5 Zeichen, breite(N) = 11*N-4, hoehe(M) = 7*M-2; also 1x1 =
-- 7x5 und 1x3 = 7x19 (Hoehe 17-21 als Toleranz).
local function local_is_ampel_shape(w, h)
  return w == 7 and (h == 5 or (h >= 17 and h <= 21))
end
local ok_adapter, monitor_adapter = pcall(require, "adapters.monitor")
local is_ampel_shape = (ok_adapter and type(monitor_adapter) == "table"
  and type(monitor_adapter.is_ampel_shape) == "function") and monitor_adapter.is_ampel_shape
  or local_is_ampel_shape

local function shape_label(h)
  return h == 5 and "1x1" or "1x3"
end

local function now_s()
  return (os.clock and os.clock()) or 0
end

-- Ein State pro Aufrufer-Modul (RT, ENERGY, FUEL), ueber M.new().
function M.new()
  local self = {
    ampel_name = nil,     -- gefundene Ampel
    painted_color = nil,  -- zuletzt gemalte Farbe
    painted_at = nil,     -- wann (now_s)
    next_probe = 0,       -- naechste Suche, solange keine Ampel bekannt ist
    lost_name = nil,      -- zuletzt verlorene Ampel: taucht sie wieder auf,
                          -- wird sofort gesucht statt erst nach PROBE_S
    -- Diagnosezeile je Nicht-Treffer nur einmal pro Kandidat, statt bei
    -- jeder Sondierung (alle PROBE_S) erneut.
    seen_non_match = {},
  }

  -- Die urspruengliche Skala jedes Kandidaten wird VOR der Groessenprobe
  -- gesichert und bei einem Fehlschlag sofort wiederhergestellt -- sonst
  -- bliebe ein faelschlich sondierter Nicht-Ampel-Monitor dauerhaft auf
  -- der Probe-Skala haengen.
  local function find_ampel_monitor(main_monitor_name)
    if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return nil end
    for _, name in ipairs(names) do
      if name ~= main_monitor_name then
        local ok_t, ptype = pcall(peripheral.getType, name)
        if ok_t and tostring(ptype):find("monitor", 1, true) then
          local ok_w, mon = pcall(peripheral.wrap, name)
          if ok_w and mon then
            local ok_orig, orig_scale = pcall(mon.getTextScale)
            local ok_scale = pcall(mon.setTextScale, 1)
            local ok_s, w, h = pcall(mon.getSize)
            if ok_scale and ok_s and type(w) == "number" and type(h) == "number" and is_ampel_shape(w, h) then
              self.seen_non_match[name] = nil
              pcall(print, "[AMPEL] Ampel gefunden: " .. tostring(name) .. " (" .. shape_label(h) .. ")")
              return name
            end
            if ok_s and type(w) == "number" and not self.seen_non_match[name] then
              self.seen_non_match[name] = true
              pcall(print, "[AMPEL] Kandidat " .. tostring(name) .. " bei Skala 1: w=" .. tostring(w)
                .. " h=" .. tostring(h) .. " (erwartet 7x5 fuer 1x1 oder 7x17-21 fuer 1x3, kein Treffer)")
            end
            if ok_scale and ok_orig and type(orig_scale) == "number" then
              pcall(mon.setTextScale, orig_scale)
            end
          end
        end
      end
    end
    return nil
  end

  -- retry_now: sofort neu suchen (Ampel abgezogen/umgebaut). Scheitert
  -- dagegen das Malen selbst, erst nach PROBE_S -- sonst sondierte jeder
  -- Tick denselben kaputten Monitor neu.
  local function forget(reason, retry_now)
    if self.ampel_name then
      pcall(print, "[AMPEL] Ampel " .. tostring(self.ampel_name) .. " weg (" .. tostring(reason) .. ") -- suche neu")
    end
    self.lost_name = self.ampel_name or self.lost_name
    self.ampel_name = nil
    self.painted_color = nil
    self.painted_at = nil
    self.next_probe = retry_now and 0 or (now_s() + M.PROBE_S)
  end

  -- render(main_monitor_name, status_key): status_key ist einer der Keys
  -- aus M.COLORS ("OK"/"LIMITED"/"WARNING"/"EMERGENCY"/"muted"; beliebig
  -- Unbekanntes faellt auf "muted" zurueck). Vollstaendig fehlerisoliert --
  -- ein Aufruf dieser Funktion kann niemals eine Exception nach aussen
  -- werfen, unabhaengig davon was intern schiefgeht.
  function self.render(main_monitor_name, status_key)
    pcall(function()
      local now = now_s()
      local mon
      if self.ampel_name then
        if self.ampel_name == main_monitor_name then
          forget("ist jetzt der Hauptmonitor", true)
        elseif not peripheral.isPresent or peripheral.isPresent(self.ampel_name) then
          local ok_w, wrapped = pcall(peripheral.wrap, self.ampel_name)
          if ok_w and wrapped then mon = wrapped else forget("nicht mehr erreichbar", true) end
        else
          forget("nicht mehr angeschlossen", true)
        end
      end
      if not self.ampel_name and self.lost_name and peripheral.isPresent
          and peripheral.isPresent(self.lost_name) then
        self.next_probe = 0 -- die verlorene Ampel ist wieder angeschlossen
        self.lost_name = nil
      end
      if not self.ampel_name and now >= self.next_probe then
        self.ampel_name = find_ampel_monitor(main_monitor_name)
        self.next_probe = now + M.PROBE_S
        if self.ampel_name then
          local ok_w, wrapped = pcall(peripheral.wrap, self.ampel_name)
          if ok_w and wrapped then mon = wrapped else forget("nicht einbindbar", false) end
        end
      end
      if not mon then return end
      local color = M.COLORS[status_key] or M.COLORS.muted
      local due = self.painted_color ~= color or self.painted_at == nil
        or now - self.painted_at >= M.REPAINT_S
      if not due then return end
      local ok_paint = pcall(function()
        mon.setBackgroundColor(color)
        mon.clear()
      end)
      if ok_paint then
        self.painted_color = color
        self.painted_at = now
      else
        forget("Malen gescheitert", false)
      end
    end)
  end

  return self
end

return M
