-- xreactor/optional/speaker_alarm.lua
--
-- Optionale Peripherie: generischer, ereignisbasierter Speaker-Support.
--
-- Zweck: ein angeschlossener Speaker (beliebiger Name, automatisch erkannt)
-- kann von JEDEM Node-Typ (nicht nur Master) fuer beliebige benannte
-- Ereignisse genutzt werden — nicht nur "CRITICAL-Alarm", sondern jeder
-- Aufrufer definiert eigene Sound-Events mit eigenem Ton/Cooldown. Ergaenzt
-- die visuelle Anzeige (Master-UI, Ampel-Monitor) um eine akustische Ebene,
-- die auch auffaellt wenn man gerade nicht auf einen Monitor schaut.
--
-- Design-Prinzip (siehe auch optional/ampel.lua): vollstaendig pcall-
-- isoliert. Fehlt der Speaker, fehlt Note Block Studio o.ä. — das Modul
-- gibt dann einfach nichts von sich, ohne den Rest des Systems zu stoeren.
--
-- Vordefinierte Ereignis-Presets (jeder Aufrufer kann eigene ergaenzen):
--   "alarm"            — dringlich, tiefer Ton (CRITICAL-Alarme; Alias:
--                         "critical" — identischer Klang, unterschiedlicher
--                         Name je nach Aufrufer-Vorliebe)
--   "clear"             — Entwarnung, heller Ton (Alarm hat sich aufgeloest)
--   "warning"           — mittlere Dringlichkeit
--   "startup"           — kurzer, freundlicher Ton beim Node-Boot
--   "node_offline"      — ein Node ist offline gegangen (unterscheidbar von
--                          "warning", damit man am Klang erkennt WAS los ist)
--   "safe_mode"         — RT-Node ist in SAFE/EMERGENCY-Zustand gewechselt
--   "capacity_learned"  — Capacity-Learning eines RT-Node abgeschlossen
--                          (positives Ereignis, kein Alarm)
--   "update_available"  — Auto-Updater hat eine neue Version erkannt

local M = {}

M.PRESETS = {
  alarm             = { instrument = "bass",   pitch = 4,  volume = 3, cooldown_ms = 8000 },
  critical          = { instrument = "bass",   pitch = 4,  volume = 3, cooldown_ms = 8000 },
  clear             = { instrument = "bell",   pitch = 12, volume = 2, cooldown_ms = 4000 },
  warning           = { instrument = "harp",   pitch = 8,  volume = 2, cooldown_ms = 8000 },
  startup           = { instrument = "chime",  pitch = 10, volume = 1, cooldown_ms = 0 },
  node_offline      = { instrument = "bit",    pitch = 6,  volume = 2, cooldown_ms = 15000 },
  safe_mode         = { instrument = "bass",   pitch = 2,  volume = 3, cooldown_ms = 8000 },
  capacity_learned  = { instrument = "pling",  pitch = 14, volume = 1, cooldown_ms = 2000 },
  update_available  = { instrument = "chime",  pitch = 8,  volume = 1, cooldown_ms = 30000 },
}

local function find_speaker()
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return nil end
  for _, name in ipairs(names) do
    local ok_t, ptype = pcall(peripheral.getType, name)
    if ok_t and tostring(ptype):find("speaker", 1, true) then
      local ok_w, spk = pcall(peripheral.wrap, name)
      if ok_w and spk then return spk end
    end
  end
  return nil
end

-- M.new(): erstellt eine Speaker-Instanz mit eigenem Cooldown-Zustand pro
-- Ereignis-Namen. Jeder Node-Typ (RT, ENERGY, MASTER, FUEL, WATER,
-- REPROCESSOR, LOG) kann seine eigene Instanz erstellen und beliebige
-- Ereignisse ausloesen, ohne sich gegenseitig zu beeinflussen.
function M.new()
  local self = { last_played_ms = {} }

  -- play(event_name, overrides): event_name ist entweder ein Key aus
  -- M.PRESETS ("alarm"/"clear"/"warning"/"startup") oder ein beliebiger
  -- eigener String, sofern overrides selbst instrument/pitch/volume/
  -- cooldown_ms mitgibt. Cooldown wird PRO event_name unabhaengig verfolgt
  -- — ein "alarm"-Cooldown blockiert kein "clear" und umgekehrt.
  -- Vollstaendig pcall-isoliert, kann keine Exception nach aussen werfen.
  function self.play(event_name, overrides)
    pcall(function()
      local preset = M.PRESETS[event_name] or {}
      overrides = overrides or {}
      local instrument = overrides.instrument or preset.instrument or "harp"
      local pitch = overrides.pitch or preset.pitch or 6
      local volume = overrides.volume or preset.volume or 3
      local cooldown_ms = overrides.cooldown_ms or preset.cooldown_ms or 5000

      local now = os.epoch and os.epoch("utc") or (os.clock() * 1000)
      local last = self.last_played_ms[event_name] or 0
      if cooldown_ms > 0 and (now - last) < cooldown_ms then return end

      local spk = find_speaker()
      if not spk then return end
      if type(spk.playNote) == "function" then
        pcall(spk.playNote, instrument, volume, pitch)
      elseif type(spk.playSound) == "function" then
        pcall(spk.playSound, "block.note_block.pling", volume, 1.0)
      end
      self.last_played_ms[event_name] = now
    end)
  end

  -- Abwaertskompatibel: notify(critical_active) entspricht dem alten,
  -- Master-spezifischen Interface (nur "alarm" wenn CRITICAL aktiv ist).
  -- Bestehende Aufrufer (z.B. services/alert_service.lua) funktionieren
  -- unveraendert weiter, ohne Anpassung.
  function self.notify(critical_active)
    if critical_active then self.play("alarm") end
  end

  return self
end

return M
