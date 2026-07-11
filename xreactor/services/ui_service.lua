local ui = {}

local function snapshot_value(value)
  if type(value) == "table" and textutils and textutils.serialize then
    local ok, serialized = pcall(textutils.serialize, value)
    if ok then
      return serialized
    end
  end
  return tostring(value)
end

function ui.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name or "UI",
    render = opts.render,
    handle_input = opts.handle_input,
    interval = opts.interval or 0.5,
    force_interval = opts.force_interval or math.max(opts.interval or 0.5, 2),
    snapshot = opts.snapshot,
    last_draw = 0,
    last_force_draw = 0,
    last_snapshot = nil
  }
  return setmetatable(self, { __index = ui })
end

local function now()
  return os.epoch("utc")
end

function ui:tick(_, event)
  if event and self.handle_input then
    self.handle_input(event)
  end
  local ts = now()
  local due = ts - self.last_draw >= self.interval * 1000
  -- Fix (2026-07-11): CRITICAL. self.snapshot(event) wurde bisher bei
  -- JEDEM einzelnen tick()-Aufruf berechnet, unabhaengig davon ob "due"
  -- ueberhaupt true war -- und tick() selbst laeuft bei JEDEM
  -- eingehenden Event (siehe nodes/support/runtime.lua run_event_loop:
  -- services:tick(nil, event) fuer JEDES modem_message/monitor_touch/
  -- key/mouse_click-Event, nicht gedrosselt). Bei einem belebten
  -- Funknetz (viele Status-Broadcasts anderer Nodes, die z.B. FUEL fuer
  -- den Fuellstand-Fallback ohnehin mithoert) konnte das dutzende Male
  -- pro Sekunde passieren -- jedes Mal wurde die teure build_status_
  -- payload() (Peripherie-Lesen, Logistik-Zusammenfassung, ...) neu
  -- berechnet, obwohl tatsaechlich gerendert sowieso hoechstens einmal
  -- pro "interval" wurde. Das ueberlastete den Computer sichtbar
  -- (verpasste Touch/Taste-Eingaben, gelegentliche kurze schwarze
  -- Aussetzer). Jetzt: fruehzeitiger Abbruch, BEVOR der teure snapshot()-
  -- Aufruf ueberhaupt passiert, wenn "due" noch nicht erreicht ist --
  -- exakt dieselbe Endentscheidung wie vorher, nur die teure Arbeit
  -- faellt weg, wenn sie sowieso verworfen wird.
  if not due then return end
  local force_due = ts - self.last_force_draw >= self.force_interval * 1000
  local current_snapshot = nil
  local snapshot_changed = false
  if self.snapshot then
    current_snapshot = snapshot_value(self.snapshot(event))
    snapshot_changed = current_snapshot ~= self.last_snapshot
  end
  local interactive = event and (event[1] == "monitor_touch" or event[1] == "key" or event[1] == "char")
  if not interactive and not snapshot_changed and not force_due then
    return
  end
  self.last_draw = ts
  if force_due then
    self.last_force_draw = ts
  end
  if self.render then
    self.render()
  end
  if self.snapshot then
    self.last_snapshot = current_snapshot
  end
end

return ui
