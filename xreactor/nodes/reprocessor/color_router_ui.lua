-- nodes/reprocessor/color_router_ui.lua
--
-- Replaces the shared FUEL valve-path router UI (nodes/fuel/router_ui.lua)
-- for REPROCESSOR: there is no valve tree -- routing to each Reprocessor
-- is just a Mekanism Logistical Sorter color (see feed_router.lua's
-- module comment for the full physical setup). This page lets the
-- operator do EVERYTHING feed_router.lua needs entirely on-screen, with
-- no config-file editing required: turn feeding on/off, pick the Sorter
-- and the SORTER-KISTE (the one chest the ME-Bridge exports into, where
-- the Sorter physically sits) from the actually detected peripherals, and
-- add/remove Reprocessor targets with a color each.
--
-- Presentation + local edit-buffer only: touches mutate a working copy
-- (enabled, sorter name, sorter_chest, targets). SPEICHERN persists it
-- (via write_config, same as any other persisted config) and applies it
-- to config.feed immediately; VERWERFEN reloads the working copy from the
-- last-saved config.feed, discarding unsaved edits.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local logistical_sorter = require("adapters.logistical_sorter")

local COLORS = logistical_sorter.COLORS
-- 51x19 ist die Standardgroesse des eingebauten Computer-Terminals
-- (siehe nodes/valve/local_ui.lua) -- REPROCESSOR hat normalerweise KEINEN
-- externen Monitor, laeuft also meistens direkt auf dem PC-Bildschirm
-- (main.lua's term.current()-Fallback). Der Router muss deshalb bei 51x19
-- vollstaendig bedienbar sein, nicht nur auf einem groesseren Monitor.
local MIN_W = 51
local MIN_H = 19
-- Unterhalb dieser Breite werden die Zielzeilen enger gepackt, damit
-- Label/Pfeile/Loeschen-Button trotzdem ohne Ueberlappung nebeneinander passen.
local COMPACT_W = 70
local EXCLUDED_TYPES = { monitor = true, modem = true }

-- mux.fit() only ever TRUNCATES text that's too long -- it never pads text
-- that's shorter than the target width. The color name cell is redrawn on
-- every color_prev/color_next tap without a full-screen clear (that tap
-- doesn't change #targets/mode, the only things render()'s layout-
-- signature check clears for), so cycling from a longer name (e.g.
-- "DARK_GRAY") to a shorter one (e.g. "INDIGO") left the old name's tail
-- on screen: "INDIGO" + leftover "RAY" = "INDIGORAY". Padding to the full
-- fixed column width every time fixes this at the source, matching nodes/
-- fuel/scada_layout.lua's left_padded_fit()/right_padded_fit() pattern for
-- the same bug class.
local function left_padded_fit(text, width)
  local fitted = mux.fit(text, width)
  if #fitted >= width then return fitted end
  return fitted .. string.rep(" ", width - #fitted)
end

-- Alle echten Sorter-Farben OHNE "NONE" -- NONE ist der Sorter-eigene
-- "keine Farbe gesetzt"-Zustand, keine echte Routing-Farbe, taucht daher
-- auf der FARBEN-Verwaltungsseite gar nicht auf.
local REAL_COLORS = {}
for _, c in ipairs(COLORS) do
  if c ~= "NONE" then REAL_COLORS[#REAL_COLORS + 1] = c end
end

-- Nur die vom Betreiber als "aktiv" markierten Farben (color_router_ui's
-- FARBEN-Seite) werden beim Durchklicken (< / >) einer Ziel-Farbe
-- angeboten -- eine deaktivierte Farbe ist im Sorter zwar weiterhin eine
-- gueltige Farbe (adapters/logistical_sorter.lua's COLORS bleibt die
-- vollstaendige, ungekuerzte Liste), soll aber nicht mehr durchgeklickt
-- werden koennen. Reihenfolge folgt REAL_COLORS, nicht der Aktivierungs-
-- Reihenfolge.
local function active_color_list(self)
  local out = {}
  for _, c in ipairs(REAL_COLORS) do
    if self.active_colors[c] then out[#out + 1] = c end
  end
  return out
end

-- 0 = Farbe ist nicht (mehr) aktiv -- z.B. weil sie nach der Zuweisung
-- deaktiviert wurde. color_prev/color_next behandeln das wie "vor dem
-- ersten/nach dem letzten Eintrag", statt abzustuerzen.
local function active_color_index(active_list, color)
  for i, c in ipairs(active_list) do
    if c == color then return i end
  end
  return 0
end

-- All peripherals that could plausibly be the SORTER-KISTE -- same
-- exclusion list nodes/fuel/router_scada.lua's chest picker uses.
local function peripheral_names()
  local out = {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then return out end
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok_type, kind = pcall(peripheral.getType, name)
    if not (ok_type and EXCLUDED_TYPES[kind]) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- Only peripherals that actually respond as a Mekanism Logistical Sorter
-- (adapters/logistical_sorter.lua's real method-set/type check) -- avoids
-- the operator picking a chest or transporter by mistake.
local function sorter_candidate_names()
  local out = {}
  for _, name in ipairs(peripheral_names()) do
    if logistical_sorter.detect(name, "REPROC") then out[#out + 1] = name end
  end
  return out
end

function M.new(opts)
  opts = opts or {}
  local config = assert(opts.config, "config required")
  local write_config = assert(opts.write_config, "write_config required")

  local self = setmetatable({
    config = config,
    write_config = write_config,
    config_path = opts.config_path or "/xreactor_config/reproc_targets.lua",
    log = opts.log or function() end,
    -- "list" | "pick_sorter" | "pick_sorter_chest" | "colors"
    mode = "list",
    scroll = 0,
    picker_scroll = 0,
    colors_scroll = 0,
    dirty = false,
    targets = {},
    sorter_name = nil,
    feed_enabled = false,
    -- sorter_chest_target: die SORTER-KISTE -- die eine Kiste, an der der
    -- Sorter physisch sitzt und in die die ME-Bridge exportiert (config.
    -- feed.sorter_chest). Eine einzelne Peripherie, keine Liste.
    sorter_chest_target = nil,
    -- active_colors: welche der REAL_COLORS per FARBEN-Seite aktiviert
    -- sind -- nur diese werden beim Durchklicken einer Ziel-Farbe (< / >)
    -- angeboten.
    active_colors = {},
    buttons = {},
  }, { __index = M })
  self:_load_working_copy()
  return self
end

function M:_load_working_copy()
  local fd = self.config.feed or {}
  local src = fd.targets or {}
  local out = {}
  for i, t in ipairs(src) do
    out[i] = { label = t.label or ("Reprocessor " .. tostring(i)), color = t.color or COLORS[1] }
  end
  self.targets = out
  self.sorter_name = fd.sorter
  self.feed_enabled = fd.enabled == true
  self.sorter_chest_target = fd.sorter_chest
  -- Ohne gespeicherte Liste sind alle echten Farben aktiv -- entspricht
  -- dem bisherigen Verhalten (jede Farbe durchklickbar), bis der
  -- Betreiber auf der FARBEN-Seite gezielt welche deaktiviert.
  local active = {}
  if type(fd.active_colors) == "table" then
    for _, c in ipairs(fd.active_colors) do active[c] = true end
  else
    for _, c in ipairs(REAL_COLORS) do active[c] = true end
  end
  self.active_colors = active
  self.dirty = false
end

function M:render(mon, _ui, _colors, should_clear)
  self.buttons = {}
  local w, h = mon.getSize()
  -- should_clear only reflects a PAGE transition (ui_router.lua switching
  -- to/from this page) -- it stays false across in-page redraws while the
  -- operator edits the target list. But the row layout below the header
  -- depends on #self.targets (the empty-state warning_box vs. the per-
  -- target row loop occupy the same screen rows with different content
  -- widths/heights). Without a full clear on exactly that transition, e.g.
  -- adding the first target while "Keine Reprocessoren konfiguriert." is
  -- still on screen leaves stale warning-box text behind (mux.text does
  -- not pad to a fixed width, unlike mux.button).
  local layout_signature = tostring(#self.targets) .. "|" .. tostring(self.mode)
  if should_clear ~= false or self._last_layout_signature ~= layout_signature then
    mux.clear(mon)
  end
  self._last_layout_signature = layout_signature

  if self.mode == "pick_sorter" then
    return self:_render_picker(mon, w, h, "SORTER WAEHLEN",
      sorter_candidate_names(), "Kein Logistical Sorter gefunden.", "pick_sorter_choose")
  elseif self.mode == "pick_sorter_chest" then
    return self:_render_picker(mon, w, h, "SORTER-KISTE WAEHLEN",
      peripheral_names(), "Keine Peripherals gefunden.", "pick_sorter_chest_choose")
  elseif self.mode == "colors" then
    return self:_render_colors(mon, w, h)
  end

  mux.header(mon, {
    title = "REPROC ROUTING", node_id = "SORTER-FARBEN", page = "Router",
    status = self.dirty and "LIMITED" or "OK", icon = "network",
  })

  if w < MIN_W or h < MIN_H then
    mux.warning_box(mon, 2, 5, math.max(20, w - 3),
      { "Monitor zu klein fuer den Farb-Router.", string.format("Mindestens %dx%d erforderlich.", MIN_W, MIN_H) },
      "WARNING")
    return mux.footer_nav(mon, h, w, { center = "REPROC FARBEN" })
  end

  -- Einziger An/Aus-Schalter fuer das gesamte Feeding-System (config.feed.
  -- enabled). Ohne dieses Flag laeuft feed_router.lua:tick() nie ueber den
  -- fruehen Return hinaus -- Sorter/Sorter-Kiste koennen also korrekt
  -- konfiguriert sein und trotzdem nie etwas befuellen, wenn dieser
  -- Schalter aus bleibt.
  local feed_toggle_btn = mux.button(mon, 2, 3, w - 3,
    "FEEDING: " .. (self.feed_enabled and "AN" or "AUS"),
    self.feed_enabled and "OK" or "OFFLINE", 1)
  feed_toggle_btn.action = "feed_toggle"
  self.buttons[#self.buttons + 1] = feed_toggle_btn

  -- SORTER/SORTER-KISTE: beide per Picker aus den tatsaechlich erkannten
  -- Peripherals waehlbar -- keine Config-Datei-Bearbeitung noetig. Die
  -- SORTER-KISTE ist die eine Kiste, in die die ME-Bridge exportiert; der
  -- Weitertransport zum jeweiligen Reprocessor uebernimmt Mekanism selbst
  -- (Sorter+Transporter), sobald die Sorter-Farbe gesetzt ist -- siehe
  -- feed_router.lua.
  local sorter_btn = mux.button(mon, 2, 4, w - 3,
    "SORTER: " .. tostring(self.sorter_name or "NICHT GESETZT"),
    self.sorter_name and "OK" or "WARNING", 1)
  sorter_btn.action = "sorter_open"
  self.buttons[#self.buttons + 1] = sorter_btn

  local sorter_chest_btn = mux.button(mon, 2, 5, w - 3,
    "SORTER-KISTE: " .. tostring(self.sorter_chest_target or "NICHT GESETZT"),
    self.sorter_chest_target and "OK" or "WARNING", 1)
  sorter_chest_btn.action = "sorter_chest_open"
  self.buttons[#self.buttons + 1] = sorter_chest_btn

  -- Verwaltung, welche Sorter-Farben ueberhaupt zur Auswahl stehen (< / >
  -- an den Zielen unten) -- eigene Unterseite, siehe _render_colors().
  local active_count = #active_color_list(self)
  local colors_btn = mux.button(mon, 2, 6, w - 3,
    "FARBEN (" .. tostring(active_count) .. "/" .. tostring(#REAL_COLORS) .. " aktiv)",
    active_count > 0 and "OK" or "WARNING", 1)
  colors_btn.action = "colors_open"
  self.buttons[#self.buttons + 1] = colors_btn

  local compact = w < COMPACT_W
  local list_top = 9

  local footer_row = h
  local action_row = footer_row - 2
  local list_bottom = action_row - 2
  local row_step = compact and 1 or 2
  local visible_rows = math.max(1, math.floor((list_bottom - list_top) / row_step) + 1)

  self.scroll = math.max(0, math.min(self.scroll, math.max(0, #self.targets - visible_rows)))
  local first = self.scroll + 1
  local last = math.min(#self.targets, self.scroll + visible_rows)

  if #self.targets == 0 then
    mux.warning_box(mon, 2, list_top, w - 3,
      { "Keine Reprocessoren konfiguriert.", "+ HINZUFUEGEN antippen." }, "WARNING")
  end

  -- color_col-Layout ist fuer w=80 (breiter Monitor) ausgelegt; im
  -- compact-Layout (schmales PC-Terminal) werden die Spalten enger
  -- gepackt, damit Label/Pfeile/Loeschen-Button trotzdem ohne
  -- Ueberlappung nebeneinander passen.
  local color_col, color_w, next_off, del_x, del_w
  if compact then
    color_col, color_w, next_off, del_x, del_w = 22, 11, 16, w - 7, 6
  else
    color_col, color_w, next_off, del_x, del_w = w - 42, 12, 17, w - 8, 7
  end
  local y = list_top
  for i = first, last do
    local t = self.targets[i]
    mux.text(mon, 2, y, left_padded_fit(string.format("%d. %s", i, tostring(t.label or "?")), color_col - 3),
      colorset.get("text"), colorset.get("background"))

    local prev_btn = mux.button(mon, color_col, y, 3, "<", "LIMITED", 1)
    prev_btn.action, prev_btn.index = "color_prev", i
    self.buttons[#self.buttons + 1] = prev_btn

    mux.text(mon, color_col + 4, y, left_padded_fit(tostring(t.color or "?"), color_w), colorset.get("OK"), colorset.get("background"))

    local next_btn = mux.button(mon, color_col + next_off, y, 3, ">", "LIMITED", 1)
    next_btn.action, next_btn.index = "color_next", i
    self.buttons[#self.buttons + 1] = next_btn

    local del_btn = mux.button(mon, del_x, y, del_w, "X", "WARNING", 1)
    del_btn.action, del_btn.index = "delete", i
    self.buttons[#self.buttons + 1] = del_btn

    y = y + row_step
  end

  if #self.targets > visible_rows then
    mux.text(mon, 2, list_bottom + 1,
      string.format("%d-%d von %d", first, last, #self.targets),
      colorset.get("muted"), colorset.get("background"))
  end

  if compact then
    local add_btn = mux.button(mon, 2, action_row, 15, "+ HINZUFUEGEN", "LIMITED", 1)
    add_btn.action = "add"
    self.buttons[#self.buttons + 1] = add_btn

    local save_btn = mux.button(mon, 18, action_row, 12,
      self.dirty and "SPEICHERN*" or "SPEICHERN", self.dirty and "LIMITED" or "OK", 1)
    save_btn.action = "save"
    self.buttons[#self.buttons + 1] = save_btn

    local discard_btn = mux.button(mon, 31, action_row, w - 32, "VERWERFEN", "OFFLINE", 1)
    discard_btn.action = "discard"
    self.buttons[#self.buttons + 1] = discard_btn
  else
    local add_btn = mux.button(mon, 2, action_row, 16, "+ HINZUFUEGEN", "LIMITED", 2)
    add_btn.action = "add"
    self.buttons[#self.buttons + 1] = add_btn

    local save_btn = mux.button(mon, w - 30, action_row, 14,
      self.dirty and "SPEICHERN *" or "SPEICHERN", self.dirty and "LIMITED" or "OK", 2)
    save_btn.action = "save"
    self.buttons[#self.buttons + 1] = save_btn

    local discard_btn = mux.button(mon, w - 14, action_row, 13, "VERWERFEN", "OFFLINE", 2)
    discard_btn.action = "discard"
    self.buttons[#self.buttons + 1] = discard_btn
  end

  return mux.footer_nav(mon, footer_row, w, { center = "REPROC FARBEN" })
end

function M:_render_picker(mon, w, h, title, names, empty_message, choose_action)
  mux.header(mon, {
    title = title, node_id = "SORTER-FARBEN", page = "Router", status = "LIMITED", icon = "network",
  })

  local list_top = 5
  local footer_row = h
  local action_row = footer_row - 2
  local list_bottom = action_row - 2
  local visible_rows = math.max(1, list_bottom - list_top + 1)

  if #names == 0 then
    mux.warning_box(mon, 2, list_top, math.max(20, w - 3), { empty_message, "ABBRECHEN antippen." }, "WARNING")
  else
    self.picker_scroll = math.max(0, math.min(self.picker_scroll, math.max(0, #names - visible_rows)))
    local first = self.picker_scroll + 1
    local last = math.min(#names, self.picker_scroll + visible_rows)
    local y = list_top
    for i = first, last do
      local name = names[i]
      mux.text(mon, 2, y, mux.fit(name, w - 14), colorset.get("text"), colorset.get("background"))
      local pick_btn = mux.button(mon, w - 10, y, 8, "WAEHLEN", "OK", 1)
      pick_btn.action, pick_btn.name = choose_action, name
      self.buttons[#self.buttons + 1] = pick_btn
      y = y + 1
    end
    if #names > visible_rows then
      mux.text(mon, 2, list_bottom + 1,
        string.format("%d-%d von %d", first, last, #names),
        colorset.get("muted"), colorset.get("background"))
    end
  end

  local cancel_btn = mux.button(mon, 2, action_row, 16, "ABBRECHEN", "OFFLINE", 2)
  cancel_btn.action = "pick_cancel"
  self.buttons[#self.buttons + 1] = cancel_btn

  return mux.footer_nav(mon, footer_row, w, { center = "REPROC FARBEN" })
end

-- FARBEN-Seite: jede der 18 echten Sorter-Farben (REAL_COLORS, ohne NONE)
-- als eigene Zeile mit AN/AUS-Umschalter -- Antippen einer Zeile schaltet
-- diese Farbe sofort aktiv/inaktiv (Arbeitskopie, erst SPEICHERN auf der
-- Hauptseite persistiert es). Nur aktive Farben werden beim Durchklicken
-- einer Ziel-Farbe (< / >) angeboten.
function M:_render_colors(mon, w, h)
  mux.header(mon, {
    title = "SORTER-FARBEN AKTIV/INAKTIV", node_id = "SORTER-FARBEN", page = "Router", status = "LIMITED", icon = "network",
  })

  local list_top = 3
  local footer_row = h
  local action_row = footer_row - 2
  local list_bottom = action_row - 2
  local visible_rows = math.max(1, list_bottom - list_top + 1)

  self.colors_scroll = math.max(0, math.min(self.colors_scroll, math.max(0, #REAL_COLORS - visible_rows)))
  local first = self.colors_scroll + 1
  local last = math.min(#REAL_COLORS, self.colors_scroll + visible_rows)
  local toggle_x, toggle_w = w - 9, 8
  local y = list_top
  for i = first, last do
    local name = REAL_COLORS[i]
    local is_active = self.active_colors[name] == true
    mux.text(mon, 2, y, left_padded_fit(name, toggle_x - 3), colorset.get("text"), colorset.get("background"))
    local toggle_btn = mux.button(mon, toggle_x, y, toggle_w, is_active and "AN" or "AUS", is_active and "OK" or "OFFLINE", 1)
    toggle_btn.action, toggle_btn.name = "color_toggle", name
    self.buttons[#self.buttons + 1] = toggle_btn
    y = y + 1
  end
  if #REAL_COLORS > visible_rows then
    mux.text(mon, 2, list_bottom + 1,
      string.format("%d-%d von %d", first, last, #REAL_COLORS),
      colorset.get("muted"), colorset.get("background"))
  end

  local back_btn = mux.button(mon, 2, action_row, 16, "ZURUECK", "OFFLINE", 2)
  back_btn.action = "colors_back"
  self.buttons[#self.buttons + 1] = back_btn

  return mux.footer_nav(mon, footer_row, w, { center = "REPROC FARBEN" })
end

function M:handle_touch(x, y)
  x, y = tonumber(x), tonumber(y)
  if not x or not y then return false end
  for _, btn in ipairs(self.buttons) do
    if x >= btn.x1 and x <= btn.x2 and y >= btn.y and y <= (btn.y2 or btn.y) then
      return self:_apply_action(btn) == true
    end
  end
  return false
end

function M:_apply_action(btn)
  if btn.action == "feed_toggle" then
    self.feed_enabled = not self.feed_enabled
    self.dirty = true
    return true
  elseif btn.action == "sorter_open" then
    self.mode = "pick_sorter"
    self.picker_scroll = 0
    return true
  elseif btn.action == "sorter_chest_open" then
    self.mode = "pick_sorter_chest"
    self.picker_scroll = 0
    return true
  elseif btn.action == "pick_cancel" then
    self.mode = "list"
    return true
  elseif btn.action == "pick_sorter_choose" then
    self.sorter_name = btn.name
    self.dirty = true
    self.mode = "list"
    return true
  elseif btn.action == "pick_sorter_chest_choose" then
    self.sorter_chest_target = btn.name
    self.dirty = true
    self.mode = "list"
    return true
  elseif btn.action == "colors_open" then
    self.mode = "colors"
    self.colors_scroll = 0
    return true
  elseif btn.action == "colors_back" then
    self.mode = "list"
    return true
  elseif btn.action == "color_toggle" then
    self.active_colors[btn.name] = not self.active_colors[btn.name]
    self.dirty = true
    return true
  elseif btn.action == "color_prev" or btn.action == "color_next" then
    local t = self.targets[btn.index]
    if not t then return false end
    local active_list = active_color_list(self)
    if #active_list == 0 then return true end
    local idx = active_color_index(active_list, t.color)
    if btn.action == "color_prev" then
      if idx <= 1 then idx = #active_list else idx = idx - 1 end
    else
      if idx == 0 or idx >= #active_list then idx = 1 else idx = idx + 1 end
    end
    t.color = active_list[idx]
    self.dirty = true
    return true
  elseif btn.action == "delete" then
    table.remove(self.targets, btn.index)
    self.dirty = true
    return true
  elseif btn.action == "add" then
    local active_list = active_color_list(self)
    self.targets[#self.targets + 1] = { label = "Reprocessor " .. tostring(#self.targets + 1), color = active_list[1] or COLORS[1] }
    self.dirty = true
    return true
  elseif btn.action == "save" then
    self:_save()
    return true
  elseif btn.action == "discard" then
    self:_load_working_copy()
    self.mode = "list"
    return true
  end
  return false
end

function M:_save()
  local targets_out = {}
  for i, t in ipairs(self.targets) do
    targets_out[i] = { label = t.label, color = t.color }
  end
  local active_colors_out = active_color_list(self)
  local out = {
    sorter = self.sorter_name, sorter_chest = self.sorter_chest_target,
    enabled = self.feed_enabled, targets = targets_out, active_colors = active_colors_out,
  }
  local ok, err = self.write_config(self.config_path, out)
  if not ok then
    self.log("WARN", "color_router_ui: Speichern fehlgeschlagen: " .. tostring(err))
    return false
  end
  self.config.feed = self.config.feed or {}
  self.config.feed.enabled = self.feed_enabled
  self.config.feed.targets = targets_out
  self.config.feed.sorter_chest = self.sorter_chest_target
  self.config.feed.sorter = self.sorter_name
  self.config.feed.active_colors = active_colors_out

  self.dirty = false
  self.log("INFO", "color_router_ui: " .. tostring(#targets_out) .. " Reprocessor-Ziel(e) gespeichert")
  return true
end

return M
