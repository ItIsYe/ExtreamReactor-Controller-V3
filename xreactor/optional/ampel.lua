-- xreactor/optional/ampel.lua
--
-- Optionale Peripherie: 1x3 Ampel-Statusmonitor.
--
-- Zweck: ein zweiter, exakt 1 Zeichen breit x 3 Zeichen hoch skalierter
-- Monitor wird automatisch erkannt (kein Config-Eintrag noetig) und mit
-- einer einzigen Vollflaechenfarbe je nach Status gefuellt — kein Text,
-- von weitem als Ampel lesbar.
--
-- Wird von nodes/rt/monitor_ui.lua und nodes/energy/ui_pages.lua genutzt
-- (vorher als duplizierter Code in beiden Dateien, hierher extrahiert
-- 2026-07-01 im Rahmen der "optionale Peripherie"-Struktur).
--
-- Design-Prinzip (gilt für alle Module in xreactor/optional/): jede
-- Funktion ist selbst vollstaendig pcall-isoliert. Ein Fehler in einem
-- optionalen Feature darf NIEMALS die Kernfunktion (Reaktorsteuerung,
-- Master-UI, etc.) beeinflussen koennen. Ein frueher, nicht ausreichend
-- isolierter erster Ampel-Versuch legte einmal kurzzeitig die komplette
-- RT-Hauptanzeige lahm — dieses Modul ist die daraus resultierende,
-- sorgfaeltig abgesicherte Neufassung.

local M = {}

-- Fix (2026-07-06): CRITICAL. Diese Werte waren rohe 24-Bit-RGB-Hex-Zahlen
-- (0x00FF00 etc.) — aber mon.setBackgroundColor() erwartet die speziellen
-- colors.xxx Bitmask-Konstanten (Zweierpotenzen: colors.white=1, colors.
-- red=16384, ...), KEINE beliebigen RGB-Werte. Ein ungueltiger Farbwert
-- wirft laut CC:Tweaked-Doku einen Fehler ("Values outside the range of
-- a valid colour will error"), der hier durch pcall() verschluckt wurde
-- — der Ampel-Bildschirm blieb dadurch dauerhaft schwarz, ohne sichtbaren
-- Fehler. Jetzt mit den echten colors-API-Konstanten.
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

  -- Fix (2026-07-07): CRITICAL REGRESSION. Der Scale-5-Fix (v337) probte
  -- JEDEN Nicht-Haupt-Monitor bei JEDEM render()-Aufruf mit setTextScale(5),
  -- um seine Groesse zu pruefen — aber wenn der Monitor NICHT die 1x3-Ampel
  -- war (z.B. ein normales Overview/Fleet/Energy-Display), blieb die Skala
  -- fuer immer bei 5 haengen, weil nie zurueckgesetzt wurde. Das ist genau
  -- der Grund fuer "erst normale UI, dann kurz gruen, dann viel zu grosse
  -- UI" — der allererste Ampel-Render-Durchlauf hat jeden anderen Monitor
  -- auf dem Node dauerhaft kaputtskaliert. Jetzt: (1) die urspruengliche
  -- Skala jedes Kandidaten wird VOR dem Probe gesichert und bei einem
  -- Fehlschlag sofort wiederhergestellt, (2) das Ergebnis wird gecacht und
  -- nur alle 30s neu geprueft statt bei jedem Tick, damit andere Monitore
  -- gar nicht erst wiederholt angefasst werden.
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
            -- Fix (2026-07-07) #2: die vorherigen zwei Versuche (Skala 5
            -- exakt 1x3, dann Skala 0.5 mit Groessen-Heuristik) waren beide
            -- unbegruendete Vermutungen ueber die CC:Tweaked-Zeichenaufloesung
            -- und haben die Ampel weiterhin nicht gefunden. Diesmal echte
            -- Herleitung: laut offizieller Doku hat ein einzelner Monitorblock
            -- bei Skala 1 exakt 7x5 Zeichen, ein 3x3-Cluster insgesamt 29x19.
            -- Daraus folgt (verifiziert gegen beide Punkte): breite(N) =
            -- 11*N-4, hoehe(M) = 7*M-2. Fuer einen 1 breit x 3 hoch Stack
            -- (N=1, M=3): breite = 11*1-4 = 7 (exakt, unabhaengig von der
            -- Hoehe, da nur 1 Spalte), hoehe = 7*3-2 = 19. w=7 wird exakt
            -- verlangt (mathematisch sicher fuer N=1), h bekommt eine kleine
            -- Toleranz (17-21) falls die tatsaechliche Bauhoehe leicht von 3
            -- Bloecken abweicht oder die Formel um 1-2 daneben liegt.
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
