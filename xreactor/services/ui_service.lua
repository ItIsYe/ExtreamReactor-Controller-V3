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
    -- Feature (2026-07-11): UI-P0.4 (siehe docs/CODING_AI_FUEL_UI_
    -- PRIORITY_FIX_2026-07-12.md). Optionaler neuer Pfad: build_model(event)
    -- baut das VOLLSTAENDIGE Model EINMAL pro Zyklus; render(model, event)
    -- bekommt genau DIESES Objekt uebergeben, statt selbst nochmal einen
    -- eigenen (moeglicherweise abweichenden) Payload/Model aufzubauen.
    -- Bewusst als ZUSAETZLICHE, abwaertskompatible Option eingefuehrt --
    -- wenn opts.build_model nicht gesetzt ist, verhaelt sich dieser Service
    -- exakt wie vorher (opts.snapshot + parameterloses opts.render()),
    -- unveraendert fuer alle anderen Rollen (WATER/REPROCESSOR/ENERGY/RT),
    -- die diesen Service ebenfalls nutzen.
    build_model = opts.build_model,
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
  local interactive = event and (event[1] == "monitor_touch" or event[1] == "mouse_click" or event[1] == "key" or event[1] == "char")
  local due = ts - self.last_draw >= self.interval * 1000
  -- Fix (2026-07-11): CRITICAL. Nach dem v380-Performance-Fix (due-Check
  -- vor dem teuren snapshot()) galt "due" weiterhin fuer JEDE Art von
  -- Event, auch fuer direkte Nutzer-Interaktion (Touch/Taste) -- eine
  -- Seitennavigation direkt nach einem Render konnte dadurch bis zu
  -- "interval" Sekunden lang NICHT tatsaechlich neu zeichnen, obwohl
  -- router:set() den Seitenindex sofort korrekt aendert. In dieser
  -- Wartezeit blieben die Footer-Touch-Zonen (siehe core/ui_router.lua)
  -- auf der alten Seite eingefroren -- mehrere schnelle Taps trafen
  -- dadurch wiederholt dieselbe (alte) Zone, der Seitenindex sprang
  -- mehrfach, aber sichtbar wurde nur das Endergebnis (oft Seite 1 oder
  -- die letzte Seite, je nachdem welche Zone getroffen wurde). Jetzt:
  -- interaktive Events umgehen die Zeit-Drossel (sofortige Reaktion),
  -- waehrend passive Netzwerk-Events (modem_message) weiterhin gedrosselt
  -- bleiben -- der Performance-Gewinn von v380 bleibt fuer den haeufigen
  -- Fall (Netzwerk-Traffic) vollstaendig erhalten.
  if not due and not interactive then return end
  local force_due = ts - self.last_force_draw >= self.force_interval * 1000

  if self.build_model then
    -- Feature (2026-07-11): UI-P0.4. Genau EIN Model-Aufbau pro Zyklus --
    -- render() bekommt DASSELBE Objekt uebergeben, das fuer den Snapshot-
    -- Vergleich benutzt wurde, statt selbst nochmal unabhaengig einen
    -- (potenziell abweichenden) Payload/Model aufzubauen.
    local model = self.build_model(event)
    local current_snapshot = snapshot_value(model and model.snapshot)
    local snapshot_changed = current_snapshot ~= self.last_snapshot
    if not interactive and not snapshot_changed and not force_due then
      return
    end
    self.last_draw = ts
    if force_due then
      self.last_force_draw = ts
    end
    if self.render then
      self.render(model, event)
    end
    self.last_snapshot = current_snapshot
    return
  end

  local current_snapshot = nil
  local snapshot_changed = false
  if self.snapshot then
    current_snapshot = snapshot_value(self.snapshot(event))
    snapshot_changed = current_snapshot ~= self.last_snapshot
  end
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
