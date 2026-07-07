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
  local self = { cache = { name = nil, last_color = nil } }

  -- Sucht einen Monitor, der NICHT der als main_monitor_name uebergebene
  -- Hauptmonitor ist, und dessen Groesse nach setTextScale(1) exakt 1x3
  -- betraegt. Gibt (name, handle) zurueck oder nil.
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
            -- Fix (2026-07-07): CRITICAL. setTextScale(1) war hier gesetzt,
            -- aber laut CC:Tweaked-Doku hat ein einzelner Monitorblock
            -- bei Scale 1 bereits eine Zeichenaufloesung von 7x5 — ein
            -- "1 breit x 3 hoch" Bloecke-Cluster ergibt bei Scale 1
            -- rechnerisch ca. 7x19 Zeichen, NIEMALS 1x3. Der w==1/h==3
            -- Check konnte bei Scale 1 also nie zutreffen — das war der
            -- eigentliche Grund, warum die Ampel trotz des Farbfixes
            -- (v327) weiterhin nicht gefunden wurde. Scale 5 (Maximum)
            -- skaliert dieselbe physische Groesse auf ca. 1x3-4 Zeichen
            -- herunter, was den Check tatsaechlich treffen kann.
            local ok_scale = pcall(mon.setTextScale, 5)
            local ok_s, w, h = pcall(mon.getSize)
            if ok_scale and ok_s and w == 1 and h == 3 then
              return name, mon
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
      local name, mon = find_ampel_monitor(main_monitor_name)
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
