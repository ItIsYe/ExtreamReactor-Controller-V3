-- nodes/reprocessor/color_router_ui.lua
--
-- Replaces the shared FUEL valve-path router UI (nodes/fuel/router_ui.lua)
-- for REPROCESSOR: there is no valve tree anymore (see feed_router.lua's
-- module comment) -- routing to each Reprocessor is just a Mekanism
-- Logistical Sorter color. This page lets the operator do EVERYTHING
-- feed_router.lua needs entirely on-screen, with no config-file editing
-- required: pick the Sorter and the shared export inlet from the actually
-- detected peripherals (same "pick from a live list" pattern FUEL's
-- router uses for its chest picker), and add/remove Reprocessor targets
-- with a color each.
--
-- Presentation + local edit-buffer only: touches mutate a working copy
-- (targets list, sorter name, export inlet). SPEICHERN persists it (via
-- write_config, same as any other persisted config) and applies it to
-- config.feed immediately; VERWERFEN reloads the working copy from the
-- last-saved config.feed, discarding unsaved edits.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local logistical_sorter = require("adapters.logistical_sorter")

local COLORS = logistical_sorter.COLORS
local MIN_W = 62
local MIN_H = 14
local EXCLUDED_TYPES = { monitor = true, modem = true }

local function color_index(color)
  for i, c in ipairs(COLORS) do
    if c == color then return i end
  end
  return 1
end

-- All peripherals that could plausibly be an export target -- same
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
    mode = "list", -- "list" | "pick_sorter" | "pick_inlet"
    scroll = 0,
    picker_scroll = 0,
    dirty = false,
    targets = {},
    sorter_name = nil,
    export_inlet = nil,
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
  self.export_inlet = fd.export_inlet
  self.dirty = false
end

function M:render(mon, _ui, _colors, should_clear)
  self.buttons = {}
  local w, h = mon.getSize()
  if should_clear ~= false then mux.clear(mon) end

  if self.mode == "pick_sorter" then
    return self:_render_picker(mon, w, h, "SORTER WAEHLEN",
      sorter_candidate_names(), "Kein Logistical Sorter gefunden.", "pick_sorter_choose")
  elseif self.mode == "pick_inlet" then
    return self:_render_picker(mon, w, h, "EXPORT-ZIEL WAEHLEN",
      peripheral_names(), "Keine Peripherals gefunden.", "pick_inlet_choose")
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

  -- Sorter/Export-Ziel: beide per Picker aus den tatsaechlich erkannten
  -- Peripherals waehlbar -- keine Config-Datei-Bearbeitung noetig.
  local half_w = math.floor((w - 5) / 2)
  local sorter_btn = mux.button(mon, 2, 3, half_w,
    "SORTER: " .. tostring(self.sorter_name or "NICHT GESETZT"),
    self.sorter_name and "OK" or "WARNING", 1)
  sorter_btn.action = "sorter_open"
  self.buttons[#self.buttons + 1] = sorter_btn

  local inlet_btn = mux.button(mon, 3 + half_w, 3, w - 3 - half_w,
    "ZIEL: " .. tostring(self.export_inlet or "NICHT GESETZT"),
    self.export_inlet and "OK" or "WARNING", 1)
  inlet_btn.action = "inlet_open"
  self.buttons[#self.buttons + 1] = inlet_btn

  local list_top = 6
  local footer_row = h
  local action_row = footer_row - 2
  local list_bottom = action_row - 2
  local visible_rows = math.max(1, math.floor((list_bottom - list_top) / 2) + 1)

  self.scroll = math.max(0, math.min(self.scroll, math.max(0, #self.targets - visible_rows)))
  local first = self.scroll + 1
  local last = math.min(#self.targets, self.scroll + visible_rows)

  if #self.targets == 0 then
    mux.warning_box(mon, 2, list_top, w - 3,
      { "Keine Reprocessoren konfiguriert.", "+ HINZUFUEGEN antippen." }, "WARNING")
  end

  local color_col = w - 42
  local y = list_top
  for i = first, last do
    local t = self.targets[i]
    mux.text(mon, 2, y, mux.fit(string.format("%d. %s", i, tostring(t.label or "?")), color_col - 3),
      colorset.get("text"), colorset.get("background"))

    local prev_btn = mux.button(mon, color_col, y, 3, "<", "LIMITED", 1)
    prev_btn.action, prev_btn.index = "color_prev", i
    self.buttons[#self.buttons + 1] = prev_btn

    mux.text(mon, color_col + 4, y, mux.fit(tostring(t.color or "?"), 12), colorset.get("OK"), colorset.get("background"))

    local next_btn = mux.button(mon, color_col + 17, y, 3, ">", "LIMITED", 1)
    next_btn.action, next_btn.index = "color_next", i
    self.buttons[#self.buttons + 1] = next_btn

    local del_btn = mux.button(mon, w - 8, y, 7, "X", "WARNING", 1)
    del_btn.action, del_btn.index = "delete", i
    self.buttons[#self.buttons + 1] = del_btn

    y = y + 2
  end

  if #self.targets > visible_rows then
    mux.text(mon, 2, list_bottom + 1,
      string.format("%d-%d von %d", first, last, #self.targets),
      colorset.get("muted"), colorset.get("background"))
  end

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
  if btn.action == "sorter_open" then
    self.mode = "pick_sorter"
    self.picker_scroll = 0
    return true
  elseif btn.action == "inlet_open" then
    self.mode = "pick_inlet"
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
  elseif btn.action == "pick_inlet_choose" then
    self.export_inlet = btn.name
    self.dirty = true
    self.mode = "list"
    return true
  elseif btn.action == "color_prev" or btn.action == "color_next" then
    local t = self.targets[btn.index]
    if not t then return false end
    local idx = color_index(t.color)
    if btn.action == "color_prev" then
      idx = idx - 1
      if idx < 1 then idx = #COLORS end
    else
      idx = idx + 1
      if idx > #COLORS then idx = 1 end
    end
    t.color = COLORS[idx]
    self.dirty = true
    return true
  elseif btn.action == "delete" then
    table.remove(self.targets, btn.index)
    self.dirty = true
    return true
  elseif btn.action == "add" then
    self.targets[#self.targets + 1] = { label = "Reprocessor " .. tostring(#self.targets + 1), color = COLORS[1] }
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
  local out = { sorter = self.sorter_name, export_inlet = self.export_inlet, targets = targets_out }
  local ok, err = self.write_config(self.config_path, out)
  if not ok then
    self.log("WARN", "color_router_ui: Speichern fehlgeschlagen: " .. tostring(err))
    return false
  end
  self.config.feed = self.config.feed or {}
  self.config.feed.targets = targets_out
  if self.sorter_name then self.config.feed.sorter = self.sorter_name end
  if self.export_inlet then self.config.feed.export_inlet = self.export_inlet end
  self.dirty = false
  self.log("INFO", "color_router_ui: " .. tostring(#targets_out) .. " Reprocessor-Ziel(e) gespeichert")
  return true
end

return M
