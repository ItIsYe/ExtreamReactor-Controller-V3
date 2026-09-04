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
    -- Optionaler Pfad: build_model(event) baut das vollstaendige Model
    -- einmal pro Zyklus; render(model, event) bekommt genau dieses Objekt,
    -- statt selbst einen eigenen Payload aufzubauen. Abwaertskompatibel --
    -- ohne opts.build_model verhaelt sich der Service wie zuvor
    -- (opts.snapshot + parameterloses opts.render()).
    build_model = opts.build_model,
    -- Optionaler Callback fuer garantiertes Logging eines Fehlers, der vor
    -- page.render() auftritt (build_model()-Fehler). Analog zu
    -- core/ui_router.lua's on_render_error.
    on_error = opts.on_error,
    last_draw = 0,
    last_force_draw = 0,
    last_snapshot = nil,
    -- UI muss auf monitor_touch/mouse_click/key sofort reagieren, meldet
    -- sich daher immer fuer Event-Ticks an.
    wants_events = true
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
  local event_kind = event and event[1]
  local interactive = event_kind == "monitor_touch" or event_kind == "mouse_click"
    or event_kind == "key" or event_kind == "char"
  local layout_change = event_kind == "monitor_resize" or event_kind == "term_resize"
  local immediate = interactive or layout_change
  local due = ts - self.last_draw >= self.interval * 1000
  -- Interaktive Events (Touch/Taste) umgehen die Zeit-Drossel fuer sofortige
  -- Reaktion, waehrend passive Netzwerk-Events (modem_message) weiterhin
  -- gedrosselt bleiben -- sonst blieben die Footer-Touch-Zonen nach einem
  -- Render bis zu "interval" Sekunden auf der alten Seite eingefroren.
  if not due and not immediate then return end
  local force_due = ts - self.last_force_draw >= self.force_interval * 1000

  if self.build_model then
    -- Genau EIN Model-Aufbau pro Zyklus -- render() bekommt dasselbe Objekt,
    -- das fuer den Snapshot-Vergleich benutzt wurde. xpcall mit Traceback
    -- und optionalem on_error-Callback, statt einen Fehler hier bis zum
    -- aeusseren service_manager-pcall entkommen zu lassen (stiller Retry,
    -- Bildschirm bliebe ohne Hinweis auf dem letzten Stand haengen).
    local ok, model = xpcall(self.build_model, function(err)
      if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end, event)
    if not ok then
      if self.on_error then pcall(self.on_error, { stage = "model_build", message = tostring(model) }) end
      return
    end
    local current_snapshot = snapshot_value(model and model.snapshot)
    local snapshot_changed = current_snapshot ~= self.last_snapshot
    if not immediate and not snapshot_changed and not force_due then
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
  if not immediate and not snapshot_changed and not force_due then
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
