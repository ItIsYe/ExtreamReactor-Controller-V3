-- xreactor/optional/ampel.lua
--
-- Optionale Peripherie: 1x3 Ampel-Statusmonitor.
--
-- Zweck: ein zweiter, exakt 1 Zeichen breit x 3 Zeichen hoch skalierter
-- Monitor wird automatisch erkannt (kein Config-Eintrag noetig) und mit
-- einer einzigen Vollflaechenfarbe je nach Status gefuellt — kein Text,
-- von weitem als Ampel lesbar.
--
-- Wird von nodes/rt/monitor_ui.lua und nodes/energy/ui_pages.lua genutzt.
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

-- Ein Cache pro Aufrufer-Modul (RT, ENERGY, ...), damit der Ampel-Monitor
-- nicht bei jedem Tick neu gecleart wird, wenn sich Name/Farbe nicht
-- geaendert haben. Jeder Aufrufer bekommt seinen eigenen Cache-State ueber
-- M.new(), damit RT- und ENERGY-Instanzen (falls beide je liefen) sich
-- nicht gegenseitig beeinflussen.
function M.new()
  local self = { cache = { name = nil, last_color = nil, resolved = false, ampel_name = nil, next_probe = 0 } }

  -- Die urspruengliche Skala jedes Kandidaten wird VOR dem Groessen-Probe
  -- gesichert und bei einem Fehlschlag sofort wiederhergestellt -- sonst
  -- bleibt ein faelschlich sondierter Nicht-Ampel-Monitor dauerhaft auf der
  -- Probe-Skala haengen. Das Ergebnis wird gecacht und nur alle 30s neu
  -- geprueft statt bei jedem Tick.
  local function probe_interval_elapsed()
    local now = (os.clock and os.clock()) or 0
    return now >= self.cache.next_probe
  end

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
            -- Geometrie bei Skala 1: ein einzelner Monitorblock hat 7x5
            -- Zeichen, ein 3x3-Cluster 29x19 -- daraus folgt breite(N) =
            -- 11*N-4, hoehe(M) = 7*M-2. Fuer einen 1 breit x 3 hoch Stack:
            -- breite = 7 (exakt), hoehe = 19 (Toleranz 17-21 fuer leichte
            -- Bauabweichungen).
            local ok_scale = pcall(mon.setTextScale, 1)
            local ok_s, w, h = pcall(mon.getSize)
            local is_ampel_shape = ok_scale and ok_s and type(w) == "number" and type(h) == "number"
              and w == 7 and h >= 17 and h <= 21
            if is_ampel_shape then
              return name, mon
            end
            -- Diagnose (nur bei Fehlschlag, siehe M.new()-Cache fuer Rate-
            -- Limit): zeigt beim naechsten Mal die tatsaechlichen Zahlen,
            -- damit eine weitere Anpassung auf echten Daten basiert statt
            -- auf einer dritten Vermutung.
            if ok_s and type(w) == "number" then
              pcall(print, "[AMPEL] Kandidat " .. tostring(name) .. " bei Skala 1: w=" .. tostring(w) .. " h=" .. tostring(h) .. " (erwartet 7x17-21, kein Treffer)")
            end
            -- Kein Treffer: Ursprungs-Skala sofort wiederherstellen, statt
            -- den Monitor bei der Sondierungs-Skala haengen zu lassen.
            if ok_scale and ok_orig and type(orig_scale) == "number" then
              pcall(mon.setTextScale, orig_scale)
            end
          end
        end
      end
    end
    return nil
  end

  -- render(main_monitor_name, status_key): status_key ist einer der Keys
  -- aus M.COLORS ("OK"/"LIMITED"/"WARNING"/"EMERGENCY"/"muted"/beliebig
  -- Unbekanntes faellt auf "muted" zurueck). Vollstaendig fehlerisoliert —
  -- ein Aufruf dieser Funktion kann niemals eine Exception nach aussen
  -- werfen, unabhaengig davon was intern schiefgeht.
  function self.render(main_monitor_name, status_key)
    pcall(function()
      local name, mon
      if self.cache.resolved and self.cache.ampel_name then
        local ok_w, cached_mon = pcall(peripheral.wrap, self.cache.ampel_name)
        if ok_w and cached_mon then name, mon = self.cache.ampel_name, cached_mon end
      end
      if not name and probe_interval_elapsed() then
        name, mon = find_ampel_monitor(main_monitor_name)
        self.cache.resolved = true
        self.cache.ampel_name = name
        self.cache.next_probe = ((os.clock and os.clock()) or 0) + 30
      end
      if not name or not mon then return end
      local color = M.COLORS[status_key] or M.COLORS.muted
      if self.cache.name == name and self.cache.last_color == color then return end
      self.cache.name = name
      self.cache.last_color = color
      mon.setBackgroundColor(color)
      mon.clear()
    end)
  end

  return self
end

return M
