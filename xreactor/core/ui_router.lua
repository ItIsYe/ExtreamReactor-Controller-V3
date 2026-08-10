local ui = require("core.ui")
local colors = require("shared.colors")

local router = {}

local function clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

function router.paginate(list, per_page, page)
  if type(list) ~= "table" then
    list = {}
  end
  local per = tonumber(per_page) or 1
  if per < 1 then
    per = 1
  end
  local total = math.max(1, math.ceil(#list / per))
  local current = clamp(page or 1, 1, total)
  local start_idx = (current - 1) * per + 1
  local end_idx = math.min(#list, current * per)
  return {
    page = current,
    total = total,
    start_index = start_idx,
    end_index = end_idx
  }
end

function router.new(mon_or_opts, opts)
  local target = nil
  if opts == nil and type(mon_or_opts) == "table" and mon_or_opts.pages then
    opts = mon_or_opts
  else
    target = mon_or_opts
  end
  opts = opts or {}
  local list_key_prev = opts.list_key_prev
  local list_key_next = opts.list_key_next
  if not list_key_prev then
    list_key_prev = {}
    if type(keys) == "table" then
      list_key_prev[keys.up] = true
      list_key_prev[keys.pageUp] = true
    end
  end
  if not list_key_next then
    list_key_next = {}
    if type(keys) == "table" then
      list_key_next[keys.down] = true
      list_key_next[keys.pageDown] = true
    end
  end
  local self = {
    mon = target,
    title = opts.title,
    pages = opts.pages or {},
    index = opts.index or 1,
    last_snapshot = nil,
    -- Feature (2026-07-12): REST-P1.1 (siehe docs/CODING_AI_FUEL_UI_
    -- PRIORITY_FIX_2026-07-12.md). core/ui_router.lua wird von mehreren
    -- Rollen gemeinsam genutzt (FUEL/WATER/REPROCESSOR/ENERGY/RT) --
    -- der Fallback-Text bei einem Renderfehler war bisher fest "FUEL UI
    -- ERROR" codiert, bei jeder anderen Rolle waere das inhaltlich
    -- falsch. error_title jetzt konfigurierbar (Default bleibt neutral).
    -- on_render_error(error_info) wird zusaetzlich zur internen error_
    -- count/last_error-Verfolgung aufgerufen -- die aufrufende Rolle kann
    -- darin garantiert loggen (siehe main.lua-Verdrahtung), statt sich
    -- auf einen Text zu verlassen, der behauptet "steht im Log", es aber
    -- durch diesen Pfad bisher nicht garantiert tat.
    -- Feature (2026-07-12): REST-P1.4 (siehe docs/CODING_AI_FUEL_UI_
    -- PRIORITY_FIX_2026-07-12.md). Rohe Zaehler fuer Input-/Model-/
    -- Renderverhalten -- WICHTIG: diese Werte duerfen NIEMALS Teil des
    -- normalen Seiten-Snapshots (last_snapshot) werden, da sie sich
    -- staendig aendern und sonst permanent neue Redraws erzwingen wuerden
    -- (die Diagnostics-Seite selbst wuerde sich sonst in eine Endlos-
    -- Neuzeichenschleife bringen). get_diagnostics() liefert sie separat.
    ui_diag = {
      frames_requested = 0, frames_committed = 0, frames_skipped = 0,
      full_clears = 0, render_errors = 0, last_render_ms = 0,
    },
    error_title = opts.error_title or "UI RENDER ERROR",
    on_render_error = opts.on_render_error,
    -- Feature (2026-07-11): UI-P0.6 (siehe docs/CODING_AI_FUEL_UI_
    -- PRIORITY_FIX_2026-07-12.md), "Mindestloesung"-Variante. Statt eines
    -- vollen Framebuffers: nur bei Boot, Seiten-, Monitor- oder Groessen-
    -- wechsel wird der Bildschirm vollstaendig geloescht (mux.clear());
    -- bei einer normalen Inhaltsaenderung (z.B. veraenderter Reservewert)
    -- ueberschreiben die Seiten nur ihre eigenen Zeilen/Felder -- setzt
    -- voraus, dass jede core/mockup_ui.lua-Zeichenfunktion ihre Flaeche
    -- selbst vollstaendig neu schreibt (fuer die zwei ungeschuetzten
    -- Faelle status_dot/kpi_strip wurde das vorab abgesichert, siehe
    -- core/mockup_ui.lua Fix-Kommentare vom selben Datum).
    last_render_page_index = nil,
    last_render_mon = nil,
    last_render_w = nil,
    last_render_h = nil,
    -- Feature (2026-07-12): REST-P1.2 (siehe docs/CODING_AI_FUEL_UI_
    -- PRIORITY_FIX_2026-07-12.md). Bisher wurde nur w/h ueberwacht -- eine
    -- REINE Textskalierungsaenderung (getTextScale(), z.B. per Klick auf
    -- den physischen Monitor selbst, ohne dass sich die BLOCK-Groesse
    -- aendert) veraendert w/h NICHT zwangsweise identisch mit einer
    -- echten Groessenaenderung und wurde dadurch nicht zuverlaessig als
    -- eigene Transition erkannt.
    last_render_scale = nil,
    shared_backbuffer = nil,
    footer = {
      prev = nil,
      next = nil,
      indicator = nil
    },
    list_controls = nil,
    key_prev = opts.key_prev,
    key_next = opts.key_next,
    list_key_prev = list_key_prev,
    list_key_next = list_key_next
  }
  return setmetatable(self, { __index = router })
end

-- Feature (2026-07-12): REST-P1.1. Oeffentliche Diagnose-Schnittstelle --
-- die rollenspezifische Diagnostics-Seite kann darueber Fehleranzahl,
-- betroffene Seite, Fehlercode/-meldung und Alter des letzten Fehlers
-- anzeigen, statt dass diese Werte nur intern im router bleiben.
function router:get_diagnostics()
  return {
    error_count = self.error_count or 0,
    last_error = self.last_error,
    -- Feature (2026-07-12): REST-P1.2. Einfacher Lifecycle-Diagnosewert --
    -- zaehlt Monitor-/Seiten-/Groessen-/Skalenwechsel, damit z.B. ein
    -- staendig flackernder physischer Monitor (Skala aendert sich
    -- wiederholt) an einer steigenden Zahl erkennbar waere.
    transition_count = self.transition_count or 0,
    -- Feature (2026-07-12): REST-P1.4. Rohe Input-/Render-Zaehler --
    -- pointer_events_received/page_handler_calls/model_builds werden
    -- ausserhalb des Routers gezaehlt (Input-Pfad bzw. build_model()) und
    -- von der aufrufenden Rolle in dieses Ergebnis eingemischt.
    frames_requested = self.ui_diag.frames_requested,
    frames_committed = self.ui_diag.frames_committed,
    frames_skipped = self.ui_diag.frames_skipped,
    full_clears = self.ui_diag.full_clears,
    render_errors = self.ui_diag.render_errors,
    last_render_ms = self.ui_diag.last_render_ms,
  }
end

function router:count()
  return #self.pages
end

function router:current()
  return self.pages[self.index]
end

function router:set(index)
  local total = math.max(1, #self.pages)
  local next_index = clamp(index, 1, total)
  if next_index ~= self.index then
    self.index = next_index
    -- Fix (2026-07-11): Frueherer Kommentar hier (v381) beschrieb einen
    -- last_draw-Reset, der noetig war um render()s eigene, SEPARATE
    -- Zeit-Drossel zu umgehen -- diese Drossel wurde inzwischen (UI-P0.5,
    -- siehe docs/CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md) komplett
    -- entfernt, der Workaround ist dadurch obsolet. Ein Reset von
    -- last_snapshot allein reicht jetzt aus, damit render()s
    -- Inhalts-Vergleich den Seitenwechsel garantiert als "geaendert"
    -- erkennt und sofort neu zeichnet.
    self.last_snapshot = nil
  end
end

function router:next()
  local total = math.max(1, #self.pages)
  local next_index = self.index + 1
  if next_index > total then
    next_index = 1
  end
  self:set(next_index)
end

function router:prev()
  local total = math.max(1, #self.pages)
  local prev_index = self.index - 1
  if prev_index < 1 then
    prev_index = total
  end
  self:set(prev_index)
end

-- Fix (2026-07-19): CRITICAL. Weder Tasten- noch Touch-Navigation hatten
-- bisher irgendeine Entprellung -- CC:Tweaked feuert bei gehaltener Taste
-- (Tastatur-Wiederholung) mehrere "key"-Events in schneller Folge, und ein
-- etwas laenger gehaltener/leicht zittriger Touch auf einem Advanced
-- Monitor kann ebenfalls mehr als ein "monitor_touch"-Event fuer denselben
-- gefuehlt EINEN Tastendruck/Tipp erzeugen. Jeder dieser Events rief
-- self:next()/self:prev() unabhaengig auf -- ein einziger, aus Nutzersicht
-- einmaliger "WEITER"-Druck konnte dadurch den Seitenindex um 2 oder mehr
-- statt um 1 erhoehen (gemeldetes Symptom: "Seite 2 wird uebersprungen",
-- der Wechsel von Seite 1 landet direkt auf Seite 3). Jetzt: eine
-- Seitennavigation (Taste ODER Footer-Touch, NICHT die separate Listen-
-- Navigation) wird innerhalb von NAV_DEBOUNCE_MS nach der letzten
-- tatsaechlich ausgefuehrten Navigation ignoriert -- der Touch/Tastendruck
-- gilt weiterhin als konsumiert (return true), nur die zweite (und jede
-- weitere) schnelle Wiederholung bewirkt keinen zusaetzlichen Seitenwechsel
-- mehr.
local NAV_DEBOUNCE_MS = 350

local function nav_debounced(self)
  local now = os.epoch and os.epoch("utc") or 0
  if self.last_nav_ts and (now - self.last_nav_ts) < NAV_DEBOUNCE_MS then
    return true
  end
  self.last_nav_ts = now
  return false
end

function router:handle_input(event)
  if not event then return end
  local kind = event[1]
  if kind == "key" then
    local key = event[2]
    if self.key_prev and self.key_prev[key] then
      if not nav_debounced(self) then self:prev() end
      return true
    end
    if self.key_next and self.key_next[key] then
      if not nav_debounced(self) then self:next() end
      return true
    end
    local list = self.list_controls
    if list then
      if self.list_key_prev and self.list_key_prev[key] and list.on_prev then
        list.on_prev()
        return true
      end
      if self.list_key_next and self.list_key_next[key] and list.on_next then
        list.on_next()
        return true
      end
    end
  elseif kind == "monitor_touch" or kind == "mouse_click" then
    local x, y = event[3], event[4]
    local prev = self.footer.prev
    if prev and y == prev.y and x >= prev.x1 and x <= prev.x2 then
      if not nav_debounced(self) then self:prev() end
      return true
    end
    local next_btn = self.footer.next
    if next_btn and y == next_btn.y and x >= next_btn.x1 and x <= next_btn.x2 then
      if not nav_debounced(self) then self:next() end
      return true
    end
    local list = self.list_controls
    if list then
      local list_prev = list.prev
      if list_prev and y == list_prev.y and x >= list_prev.x1 and x <= list_prev.x2 then
        if list.on_prev then list.on_prev() end
        return true
      end
      local list_next = list.next
      if list_next and y == list_next.y and x >= list_next.x1 and x <= list_next.x2 then
        if list.on_next then list.on_next() end
        return true
      end
    end
  end
  return false
end

local function prepare_render_target(self, mon, width, height)
  -- Existing Window targets (notably FUEL) own their visibility lifecycle.
  -- Physical CC:Tweaked monitors do not expose setVisible().
  if type(mon) ~= "table" or type(mon.setVisible) == "function" then
    return mon, false, false
  end
  if type(window) ~= "table" or type(window.create) ~= "function"
      or type(width) ~= "number" or type(height) ~= "number"
      or width < 1 or height < 1 then
    self.shared_backbuffer = nil
    return mon, false, false
  end

  local cached = self.shared_backbuffer
  local created = false
  if not cached or cached.parent ~= mon or cached.width ~= width or cached.height ~= height
      or type(cached.target) ~= "table" then
    local ok, target = pcall(window.create, mon, 1, 1, width, height, false)
    if not ok or not target then
      self.shared_backbuffer = nil
      return mon, false, false
    end
    cached = { parent = mon, width = width, height = height, target = target }
    self.shared_backbuffer = cached
    created = true
    ui.invalidate(target)
  end
  pcall(cached.target.setVisible, false)
  return cached.target, true, created
end

local function publish_render_target(target, buffered)
  if not buffered or not target then return end
  pcall(target.setVisible, true)
  if type(target.redraw) == "function" then pcall(target.redraw) end
end

local function build_snapshot(page_name, model)
  local payload
  if model and model.snapshot ~= nil then
    payload = { page = page_name or "", snapshot = model.snapshot }
  else
    payload = { page = page_name or "", model = model or {} }
  end
  if textutils and textutils.serialize then
    local ok, result = pcall(textutils.serialize, payload)
    if ok then
      return result
    end
  end
  return tostring(payload)
end

function router:render_list_controls(mon, opts)
  if not mon then return end
  opts = opts or {}
  local _, h = ui.getSize(mon)
  if not h then
    return
  end
  local page = opts.page or 1
  local total = opts.total or 1
  local label = opts.label or "List"
  local x = opts.x or 2
  local y = opts.y or (h - 1)
  if y < 1 then
    y = 1
  end
  local text = ("< %s %d/%d >"):format(label, page, total)
  ui.text(mon, x, y, text, colors.get("text"), colors.get("background"))
  self.list_controls = {
    prev = { x1 = x, x2 = x + 1, y = y },
    next = { x1 = x + #text - 1, x2 = x + #text - 1, y = y },
    on_prev = opts.on_prev,
    on_next = opts.on_next
  }
  return self.list_controls
end

function router:render(mon, model)
  self.ui_diag.frames_requested = self.ui_diag.frames_requested + 1
  if not mon then
    -- Fix (2026-07-12): REST-P1.2. Wenn der Monitor komplett verschwindet
    -- (peripheral_detach), gab render() bisher einfach nur zurueck --
    -- die Footer-/Listen-Touchzonen von VOR der Trennung blieben aktiv
    -- gesetzt. Ein (versehentlicher) Touch-Event auf einem inzwischen
    -- ungueltigen/anderen Objekt haette dadurch stillschweigend falsche
    -- Koordinaten benutzt. Jetzt: Zonen und die gespeicherte Geometrie
    -- explizit verwerfen, damit ein Wiederanschluss (auch als neues
    -- Monitor-Objekt) sicher wieder als Transition erkannt wird.
    self.footer.prev, self.footer.next, self.footer.indicator = nil, nil, nil
    self.list_controls = nil
    self.last_render_mon = nil
    self.shared_backbuffer = nil
    return
  end
  -- Shared physical-monitor buffering is established only after transition
  -- detection below. Existing Window targets are deliberately not wrapped.
  -- Fix (2026-07-11): UI-P0.5 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_
  -- FIX_2026-07-12.md). Diese Funktion hatte bisher eine EIGENE,
  -- unabhaengige Zeit-Drossel (self.interval/self.last_draw) zusaetzlich
  -- zu der bereits vorhandenen aeusseren Drossel in services/ui_service.lua.
  -- Ein Seitenwechsel setzte zwar last_snapshot zurueck (siehe router:set()),
  -- aber solange DIESE innere Zeit-Drossel noch nicht abgelaufen war, kam
  -- render() trotzdem nie bis zum eigentlichen Zeichnen -- Footer-Touch-
  -- Zonen blieben dadurch auf der alten Seite eingefroren. v381 hat das nur
  -- kaschiert (last_draw bei jedem Seitenwechsel mit zurueckgesetzt), ohne
  -- die eigentliche doppelte Zustaendigkeit zu beseitigen. Jetzt: Zeit-
  -- planung liegt ausschliesslich in ui_service.lua (dessen "due"/
  -- "interactive"-Logik entscheidet bereits, WANN render() ueberhaupt
  -- aufgerufen wird) -- diese Funktion hier entscheidet nur noch anhand
  -- des Inhalts-Snapshots, ob sich am WAS etwas geaendert hat.
  local page = self:current()

  -- Feature (2026-07-11): UI-P1.2 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_
  -- FIX_2026-07-12.md). Transitions-Erkennung MUSS vor dem Inhalts-
  -- Snapshot-Vergleich passieren: ein Monitorwechsel (oder Groessen-/
  -- Skalenaenderung) bei ansonsten UNVERAENDERTEM Model wuerde vom reinen
  -- Inhalts-Snapshot gar nicht erkannt -- render() haette sonst komplett
  -- uebersprungen, der neue Monitor waere NIE tatsaechlich gezeichnet
  -- worden und die alten Touch-Zonen (footer.prev/next) haetten
  -- faelschlich weiter auf den alten Monitor gezeigt.
  local cur_w, cur_h = ui.getSize(mon)
  -- Feature (2026-07-12): REST-P1.2. getTextScale() ist nicht auf jedem
  -- Monitor-Wrapper garantiert vorhanden (z.B. term.current() im
  -- Terminal-Fallback) -- pcall-abgesichert, nil bei fehlender Methode
  -- oder Fehlschlag zaehlt einfach nicht als eigene Transition-Quelle.
  local scale_ok, cur_scale = pcall(mon.getTextScale)
  if not scale_ok then cur_scale = nil end
  local is_transition = (self.last_render_mon ~= mon)
    or (self.last_render_page_index ~= self.index)
    or (self.last_render_w ~= cur_w)
    or (self.last_render_h ~= cur_h)
    or (self.last_render_scale ~= cur_scale)

  local snapshot = build_snapshot(page and page.name, model)
  if not is_transition and snapshot == self.last_snapshot then
    self.ui_diag.frames_skipped = self.ui_diag.frames_skipped + 1
    return
  end
  self.ui_diag.frames_committed = self.ui_diag.frames_committed + 1
  local render_start_ms = os.epoch and os.epoch("utc") or nil
  self.last_snapshot = snapshot
  -- Fix: list_controls nur bei Transition (Seiten-/Monitor-Wechsel) zurücksetzen,
  -- nicht bei normalem Inhalt-Redraw — sonst verschwinden Touch-Zonen kurz
  if is_transition then self.list_controls = nil end

  -- Feature (2026-07-11): UI-P0.6. should_clear ist true bei Erstrender,
  -- Seitenwechsel, Monitorwechsel oder Groessen-/Skalenaenderung -- bei
  -- einer normalen Inhaltsaenderung (der einzige Grund, warum wir bis
  -- hierhin ueberhaupt gekommen sind, siehe Snapshot-Check oben) bleibt
  -- should_clear false, die Seite ueberschreibt dann nur ihre eigenen
  -- Felder statt den kompletten Bildschirm zu loeschen.
  local should_clear = is_transition
  self.last_render_mon = mon
  self.last_render_page_index = self.index
  self.last_render_w = cur_w
  self.last_render_h = cur_h
  self.last_render_scale = cur_scale
  if is_transition then
    -- Feature (2026-07-12): REST-P1.2. Nach JEDER Transition (Monitor/
    -- Seite/Groesse/Skala) muessen die Footer- und Listen-Touchzonen
    -- explizit verworfen werden -- sie stammen sonst noch von der ALTEN
    -- Geometrie und wuerden erst beim naechsten tatsaechlichen Touch-
    -- Handling (zu spaet) durch die neuen Werte ueberschrieben. Das
    -- eigentliche Neuzeichnen mit den frischen Zonen passiert weiter
    -- unten in genau diesem Aufruf.
    self.footer.prev, self.footer.next, self.footer.indicator = nil, nil, nil
    self.list_controls = nil
    self.transition_count = (self.transition_count or 0) + 1
    self.ui_diag.full_clears = self.ui_diag.full_clears + 1
  end

  local render_target, buffered, buffer_created = prepare_render_target(self, mon, cur_w, cur_h)
  if buffer_created and not should_clear then
    -- A newly-created hidden window starts without a trustworthy frame even if
    -- the physical monitor/model itself did not transition. Force one complete
    -- render into the new buffer before publishing it.
    should_clear = true
    self.ui_diag.full_clears = self.ui_diag.full_clears + 1
  end
  mon = render_target
  ui.begin_frame(mon)

  -- Feature (2026-07-11): UI-P1.1. Ein Fehler in page.render() wurde
  -- bisher entweder gar nicht abgefangen (Absturz bis zum aeusseren
  -- service_manager-pcall, der Bildschirm blieb dann auf dem letzten
  -- Stand oder halb gezeichnet stehen) oder durch grossflaechige pcalls
  -- in aufrufenden Modulen stillschweigend verschluckt -- beides fuehrt
  -- zu einem schwarzen/veralteten Monitor ohne erkennbare Ursache. Jetzt:
  -- page.render() wird hier gezielt pcall-abgesichert, ein Fehler zeigt
  -- eine minimale, aus einfachen ui.*-Grundfunktionen aufgebaute
  -- Fallback-Seite (unabhaengig von der potenziell fehlerhaften Seiten-
  -- Zeichenfunktion) UND wird in self.last_error/self.error_count fuer
  -- die Diagnostics-Seite festgehalten -- der Node selbst stuerzt dabei
  -- nie ab, der Nutzer sieht aber IMMER einen erklaerten Zustand statt
  -- Stille.
  local page_footer = nil
  if page and page.render then
    -- Fix (2026-07-12): REST-P1.1. pcall() -> xpcall() mit debug.traceback
    -- (derselbe bereits im Projekt etablierte Fallback-Pattern wie
    -- core/ui.lua's redirect()) -- last_error.message enthaelt jetzt den
    -- vollstaendigen Stack statt nur der letzten Fehlerzeile, wesentlich
    -- hilfreicher fuer die tatsaechliche Fehlersuche.
    local ok, result = xpcall(function() return page.render(mon, model, should_clear) end, function(err)
      if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end)
    if ok then
      page_footer = result
    else
      self.error_count = (self.error_count or 0) + 1
      self.ui_diag.render_errors = self.ui_diag.render_errors + 1
      self.last_error = {
        page = tostring(page.name or "?"),
        code = "RENDER_FAILED",
        message = tostring(result),
        ts = os.epoch and os.epoch("utc") or nil,
      }
      -- Fix (2026-07-12): REST-P1.1. Die Fallbackseite behauptete bisher
      -- "Details im LOG_COLLECTOR-Export", ohne dass dieser Pfad selbst
      -- jemals tatsaechlich geloggt haette -- garantiert jetzt ueber den
      -- optionalen on_render_error-Callback, den die aufrufende Rolle
      -- an einen echten Logger anschliessen kann (siehe main.lua).
      if self.on_render_error then pcall(self.on_render_error, self.last_error) end
      pcall(function()
        ui.clear(mon)
        ui.text(mon, 2, 2, self.error_title, colors.get("WARNING"), colors.get("background"))
        ui.text(mon, 2, 4, "Seite: " .. tostring(page.name or "?"), colors.get("text"), colors.get("background"))
        ui.text(mon, 2, 5, "Code: RENDER_FAILED", colors.get("text"), colors.get("background"))
        ui.text(mon, 2, 7, "Details im LOG_COLLECTOR-Export.", colors.get("muted"), colors.get("background"))
        ui.text(mon, 2, 9, "Naechster Zyklus versucht erneut zu zeichnen.", colors.get("muted"), colors.get("background"))
      end)
    end
  end
  if render_start_ms then
    self.ui_diag.last_render_ms = (os.epoch and os.epoch("utc") or render_start_ms) - render_start_ms
  end
  local w, h = ui.getSize(mon)
  if not w or not h then
    publish_render_target(mon, buffered)
    return
  end
  -- Fix (2026-07-05): wenn die Seite selbst schon einen sichtbaren Footer
  -- mit ZURUECK/WEITER-Buttons gezeichnet hat (mux.footer_nav(), gibt
  -- { left = {x1,x2,y}, right = {x1,x2,y} } zurueck), NICHT zusaetzlich
  -- einen eigenen "< Page X/Y >"-Indikator ueber dieselbe Zeile zeichnen —
  -- das ueberschrieb den sichtbaren Text und liess trotzdem nur die
  -- eigenen (jetzt unsichtbaren) Touch-Zonen aktiv, waehrend die
  -- tatsaechlich sichtbaren Buttons nie eine funktionierende Touch-Zone
  -- hatten. Stattdessen: footer.prev/next direkt auf die von der Seite
  -- zurueckgegebenen, tatsaechlich sichtbaren Button-Koordinaten legen.
  if type(page_footer) == "table" and page_footer.left and page_footer.right then
    self.footer.prev = { x1 = page_footer.left.x1, x2 = page_footer.left.x2, y = page_footer.left.y }
    self.footer.next = { x1 = page_footer.right.x1, x2 = page_footer.right.x2, y = page_footer.right.y }
    self.footer.indicator = nil
    publish_render_target(mon, buffered)
    return
  end
  local page_count = math.max(1, #self.pages)
  local indicator = ("< Page %d/%d >"):format(self.index, page_count)
  ui.rightText(mon, 2, h, w - 2, indicator, colors.get("text"), colors.get("background"))
  local start = 2 + math.max(0, (w - 2) - #indicator)
  self.footer.prev = { x1 = start, x2 = start + 1, y = h }
  self.footer.next = { x1 = start + #indicator - 1, x2 = start + #indicator - 1, y = h }
  self.footer.indicator = { x1 = start, x2 = start + #indicator, y = h }
  publish_render_target(mon, buffered)
end

return router
