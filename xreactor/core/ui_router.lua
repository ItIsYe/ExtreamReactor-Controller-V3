local ui = require("core.ui")
local colors = require("shared.colors")
local window_buffer = require("core.window_buffer")

local router = {}

local function wrapped_peripheral_name(mon)
  if type(mon) ~= "table" or type(peripheral) ~= "table"
      or type(peripheral.getName) ~= "function" then return nil end
  local ok, name = pcall(peripheral.getName, mon)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

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
    -- error_title konfigurierbar, da core/ui_router.lua von mehreren
    -- Rollen geteilt wird (FUEL/WATER/REPROCESSOR/ENERGY/RT) -- ein fest
    -- codierter Fallback-Text waere bei den meisten Rollen falsch.
    -- on_render_error(error_info) laesst die aufrufende Rolle garantiert
    -- loggen, statt sich auf einen Text zu verlassen, der nur behauptet
    -- "steht im Log".
    --
    -- Rohe Zaehler fuer Input-/Model-/Renderverhalten -- duerfen NIEMALS
    -- Teil des normalen Seiten-Snapshots (last_snapshot) werden, da sie
    -- sich staendig aendern und sonst permanent neue Redraws erzwingen
    -- wuerden. get_diagnostics() liefert sie separat.
    ui_diag = {
      frames_requested = 0, frames_committed = 0, frames_skipped = 0,
      full_clears = 0, render_errors = 0, last_render_ms = 0,
      foreign_monitor_touches = 0,
    },
    error_title = opts.error_title or "UI RENDER ERROR",
    on_render_error = opts.on_render_error,
    -- Statt eines vollen Framebuffers: nur bei Boot-, Seiten-, Monitor-
    -- oder Groessenwechsel wird der Bildschirm vollstaendig geloescht
    -- (mux.clear()); bei normaler Inhaltsaenderung ueberschreiben die
    -- Seiten nur ihre eigenen Zeilen/Felder -- setzt voraus, dass jede
    -- core/mockup_ui.lua-Zeichenfunktion ihre Flaeche selbst vollstaendig
    -- neu schreibt.
    last_render_page_index = nil,
    last_render_mon = nil,
    last_render_mon_name = nil,
    last_render_w = nil,
    last_render_h = nil,
    -- Separat von w/h ueberwacht -- eine reine Textskalierungsaenderung
    -- (getTextScale()) veraendert w/h nicht zwangsweise identisch mit einer
    -- echten Groessenaenderung.
    last_render_scale = nil,
    footer = {
      prev = nil,
      next = nil,
      indicator = nil
    },
    list_controls = nil,
    key_prev = opts.key_prev,
    key_next = opts.key_next,
    list_key_prev = list_key_prev,
    list_key_next = list_key_next,
    monitor_name = opts.monitor_name,
    layout_invalidated = false,
    shared_surface = window_buffer.new(),
  }
  return setmetatable(self, { __index = router })
end

-- Oeffentliche Diagnose-Schnittstelle -- die rollenspezifische
-- Diagnostics-Seite kann darueber Fehleranzahl, betroffene Seite,
-- Fehlercode/-meldung und Alter des letzten Fehlers anzeigen.
function router:get_diagnostics()
  return {
    error_count = self.error_count or 0,
    last_error = self.last_error,
    -- Zaehlt Monitor-/Seiten-/Groessen-/Skalenwechsel, damit z.B. ein
    -- staendig flackernder physischer Monitor erkennbar waere.
    transition_count = self.transition_count or 0,
    -- pointer_events_received/page_handler_calls/model_builds werden
    -- ausserhalb des Routers gezaehlt und von der aufrufenden Rolle
    -- in dieses Ergebnis eingemischt.
    frames_requested = self.ui_diag.frames_requested,
    frames_committed = self.ui_diag.frames_committed,
    frames_skipped = self.ui_diag.frames_skipped,
    full_clears = self.ui_diag.full_clears,
    render_errors = self.ui_diag.render_errors,
    last_render_ms = self.ui_diag.last_render_ms,
    foreign_monitor_touches = self.ui_diag.foreign_monitor_touches,
    -- Compatibility name used by the existing diagnostics page/tests.
    ignored_monitor_events = self.ui_diag.foreign_monitor_touches,
    monitor_name = self.monitor_name or self.last_render_mon_name,
  }
end

function router:count()
  return #self.pages
end

function router:current()
  return self.pages[self.index]
end

function router:set_monitor_name(name)
  if name ~= nil and type(name) ~= "string" then return false end
  if self.monitor_name ~= name then
    self.monitor_name = name
    self:invalidate_layout()
  end
  return true
end

function router:monitor_touch_matches(event)
  if not event or event[1] ~= "monitor_touch" then return true end
  local expected = self.monitor_name or self.last_render_mon_name
  return expected == nil or event[2] == expected
end

function router:invalidate_layout()
  self.layout_invalidated = true
end

function router:invalidate_content()
  self.last_snapshot = nil
end

function router:set(index)
  local total = math.max(1, #self.pages)
  local next_index = clamp(index, 1, total)
  if next_index ~= self.index then
    self.index = next_index
    -- Ein Reset von last_snapshot reicht aus, damit render()s
    -- Inhalts-Vergleich den Seitenwechsel als "geaendert" erkennt und
    -- sofort neu zeichnet.
    self:invalidate_content()
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

function router:handle_input(event)
  if not event then return end
  local kind = event[1]
  if kind == "monitor_touch" and not self:monitor_touch_matches(event) then
    self.ui_diag.foreign_monitor_touches = self.ui_diag.foreign_monitor_touches + 1
    return true
  end
  if kind == "key" then
    local key = event[2]
    local is_held = event[3] == true
    if self.key_prev and self.key_prev[key] then
      if not is_held then self:prev() end
      return true
    end
    if self.key_next and self.key_next[key] then
      if not is_held then self:next() end
      return true
    end
    local list = self.list_controls
    if list then
      if self.list_key_prev and self.list_key_prev[key] and list.on_prev then
        if not is_held then list.on_prev() end
        return true
      end
      if self.list_key_next and self.list_key_next[key] and list.on_next then
        if not is_held then list.on_next() end
        return true
      end
    end
  elseif kind == "monitor_touch" or kind == "mouse_click" then
    local x, y = event[3], event[4]
    local prev = self.footer.prev
    if prev and y == prev.y and x >= prev.x1 and x <= prev.x2 then
      self:prev()
      return true
    end
    local next_btn = self.footer.next
    if next_btn and y == next_btn.y and x >= next_btn.x1 and x <= next_btn.x2 then
      self:next()
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

local function inspect_frame(self, mon, model)
  local page = self:current()
  local width, height = ui.getSize(mon)
  local scale = nil
  if mon and type(mon.getTextScale) == "function" then
    local ok, value = pcall(mon.getTextScale)
    if ok then scale = value end
  end
  local monitor_name = self.monitor_name or wrapped_peripheral_name(mon)
  local transition = self.layout_invalidated == true
    or self.last_render_mon ~= mon
    or self.last_render_mon_name ~= monitor_name
    or self.last_render_page_index ~= self.index
    or self.last_render_w ~= width
    or self.last_render_h ~= height
    or self.last_render_scale ~= scale
  local snapshot = build_snapshot(page and page.name, model)
  local navigation_missing = self.footer.prev == nil or self.footer.next == nil
  return transition, snapshot, width, height, scale, navigation_missing, monitor_name
end

function router:needs_render(mon, model)
  if not mon then return false end
  local transition, snapshot, _, _, _, navigation_missing = inspect_frame(self, mon, model)
  return transition or navigation_missing or snapshot ~= self.last_snapshot
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
    self.footer.prev, self.footer.next, self.footer.indicator = nil, nil, nil
    self.list_controls = nil
    self.last_render_mon = nil
    self.last_render_mon_name = nil
    self.last_render_page_index = nil
    self.last_render_w = nil
    self.last_render_h = nil
    self.last_render_scale = nil
    self.last_snapshot = nil
    self.layout_invalidated = true
    if self.shared_surface then self.shared_surface:bind(nil) end
    return false
  end

  local page = self:current()
  local is_transition, snapshot, cur_w, cur_h, cur_scale,
    navigation_missing, resolved_name = inspect_frame(self, mon, model)
  if not is_transition and not navigation_missing and snapshot == self.last_snapshot then
    self.ui_diag.frames_skipped = self.ui_diag.frames_skipped + 1
    return false
  end

  local render_start_ms = os.epoch and os.epoch("utc") or nil
  local should_clear = is_transition
  local previous_footer = {
    prev = self.footer.prev,
    next = self.footer.next,
    indicator = self.footer.indicator,
  }
  local previous_list_controls = self.list_controls
  if is_transition then
    self.footer.prev, self.footer.next, self.footer.indicator = nil, nil, nil
    self.list_controls = nil
  end

  local function draw_frame(target)
    ui.begin_frame(target)
    local page_footer = nil
    if page and page.render then
      local ok, result = xpcall(function()
        return page.render(target, model, should_clear)
      end, function(err)
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
        if self.on_render_error then pcall(self.on_render_error, self.last_error) end
        local fallback_ok, fallback_err = pcall(function()
          ui.clear(target)
          ui.text(target, 2, 2, self.error_title, colors.get("WARNING"), colors.get("background"))
          ui.text(target, 2, 4, "Seite: " .. tostring(page.name or "?"), colors.get("text"), colors.get("background"))
          ui.text(target, 2, 5, "Code: RENDER_FAILED", colors.get("text"), colors.get("background"))
          ui.text(target, 2, 7, "Details im LOG_COLLECTOR-Export.", colors.get("muted"), colors.get("background"))
          ui.text(target, 2, 9, "Naechster Zyklus versucht erneut zu zeichnen.", colors.get("muted"), colors.get("background"))
        end)
        if not fallback_ok then error(fallback_err, 0) end
      end
    end

    local width, height = ui.getSize(target)
    if not width or not height then return true end
    if type(page_footer) == "table" and page_footer.left and page_footer.right then
      self.footer.prev = {
        x1 = page_footer.left.x1, x2 = page_footer.left.x2, y = page_footer.left.y,
      }
      self.footer.next = {
        x1 = page_footer.right.x1, x2 = page_footer.right.x2, y = page_footer.right.y,
      }
      self.footer.indicator = nil
      return true
    end

    local page_count = math.max(1, #self.pages)
    local indicator = ("< Page %d/%d >"):format(self.index, page_count)
    ui.rightText(target, 2, height, width - 2, indicator,
      colors.get("text"), colors.get("background"))
    local start = 2 + math.max(0, (width - 2) - #indicator)
    self.footer.prev = { x1 = start, x2 = start + 1, y = height }
    self.footer.next = {
      x1 = start + #indicator - 1, x2 = start + #indicator - 1, y = height,
    }
    self.footer.indicator = { x1 = start, x2 = start + #indicator, y = height }
    return true
  end

  local ok, result
  if type(mon.setVisible) == "function" then
    -- FUEL already passes an actual Window and owns its visibility lifecycle.
    -- Never double-buffer or publish a Window supplied by a caller.
    if self.shared_surface then self.shared_surface:bind(nil) end
    ok, result = xpcall(function()
      return draw_frame(mon)
    end, function(err)
      if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end)
  else
    local _, surface_changed = self.shared_surface:bind(mon, resolved_name)
    if surface_changed then should_clear = true end
    ok, result = pcall(self.shared_surface.render, self.shared_surface, draw_frame)
  end

  if not ok then
    self.footer.prev = previous_footer.prev
    self.footer.next = previous_footer.next
    self.footer.indicator = previous_footer.indicator
    self.list_controls = previous_list_controls
    self.layout_invalidated = true
    self.error_count = (self.error_count or 0) + 1
    self.ui_diag.render_errors = self.ui_diag.render_errors + 1
    self.last_error = {
      page = tostring(page and page.name or "?"),
      code = "FRAME_FAILED",
      message = tostring(result),
      ts = os.epoch and os.epoch("utc") or nil,
    }
    if self.on_render_error then pcall(self.on_render_error, self.last_error) end
    error(result, 0)
  end

  self.last_snapshot = snapshot
  self.last_render_mon = mon
  self.last_render_mon_name = resolved_name
  self.last_render_page_index = self.index
  self.last_render_w = cur_w
  self.last_render_h = cur_h
  self.last_render_scale = cur_scale
  self.layout_invalidated = false
  self.ui_diag.frames_committed = self.ui_diag.frames_committed + 1
  if should_clear then self.ui_diag.full_clears = self.ui_diag.full_clears + 1 end
  if is_transition then self.transition_count = (self.transition_count or 0) + 1 end
  if render_start_ms then
    self.ui_diag.last_render_ms =
      (os.epoch and os.epoch("utc") or render_start_ms) - render_start_ms
  end
  return result ~= false
end

return router
