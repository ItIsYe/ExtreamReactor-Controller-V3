-- xreactor/optional/speaker_alarm.lua
--
-- Optionale Peripherie: akustischer Alarm über einen CC:Tweaked Speaker.
--
-- Zweck: ein angeschlossener Speaker (beliebiger Name, automatisch erkannt)
-- spielt einen Warnton, sobald ein CRITICAL-Alarm aktiv ist. Ergaenzt die
-- visuelle Anzeige (Master-UI, Ampel-Monitor) um eine akustische Ebene, die
-- auch auffällt wenn man gerade nicht auf einen Monitor schaut.
--
-- Design-Prinzip (siehe auch optional/ampel.lua): vollstaendig pcall-
-- isoliert. Fehlt der Speaker, fehlt Note Block Studio o.ä. — das Modul
-- gibt dann einfach nichts von sich, ohne den Rest des Systems zu stoeren.

local M = {}

-- Nicht zu oft feuern: ein Alarmton alle COOLDOWN_MS, solange CRITICAL
-- aktiv bleibt, statt bei jedem einzelnen Tick zu piepen (das waere sowohl
-- nervig als auch — analog zum frueheren "Overspeed brake pending"-Log-
-- Spam-Bug — potenziell ein Performance-/Spam-Problem, wenn play_sound()
-- sehr haeufig aufgerufen wird).
local COOLDOWN_MS = 8000

function M.new(opts)
  opts = opts or {}
  local self = {
    last_played_ms = 0,
    instrument = opts.instrument or "harp",
    pitch = opts.pitch or 6,
    volume = opts.volume or 3,
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

  -- notify(critical_active): critical_active ist ein Boolean, ob gerade
  -- mindestens ein CRITICAL-Alarm aktiv ist (z.B. counts.CRITICAL > 0 vom
  -- alert_service). Bei jedem Aufruf mit critical_active=true wird
  -- (unter Beachtung des Cooldowns) ein kurzer Alarmton gespielt.
  -- Vollstaendig pcall-isoliert, kann keine Exception nach aussen werfen.
  function self.notify(critical_active)
    if not critical_active then return end
    pcall(function()
      local now = os.epoch and os.epoch("utc") or (os.clock() * 1000)
      if (now - self.last_played_ms) < COOLDOWN_MS then return end
      local spk = find_speaker()
      if not spk then return end
      if type(spk.playNote) == "function" then
        -- playNote(instrument, volume, pitch) — zwei kurze Toene im
        -- Wechsel klingen eher nach "Alarm" als ein einzelner Ton.
        pcall(spk.playNote, self.instrument, self.volume, self.pitch)
      elseif type(spk.playSound) == "function" then
        pcall(spk.playSound, "block.note_block.pling", self.volume, 1.0)
      end
      self.last_played_ms = now
    end)
  end

  return self
end

return M
