-- nodes/fuel/router_ui.lua
--
-- Single-screen FUEL reactor manager (2026-09-04 rewrite). Replaces the old
-- TREE/EDIT tab pair (a hand-maintained valve-route tree, loosely linked by
-- matching string labels to a separately hand-maintained reactor demand
-- list) with ONE reactor list, each entry carrying everything FUEL needs
-- for that reactor: reactor_id/label (learned from the owning RT node's
-- own broadcasts, never typed by hand), the valve path to it, its delivery
-- inlet, and its resupply thresholds. There is no `item` field anywhere --
-- logistics_router.lua decides Uranium vs Blutonium and Ingot vs Block
-- automatically on every delivery (see its build_fuel_families()/
-- pick_fuel_family()/pick_fuel_form()).
--
-- u.mode (this page's only internal state machine):
--   "list"       -- the main screen: every configured reactor, tap a row to
--                    edit it, or EINLERNEN to add one from a live RT
--                    broadcast.
--   "learn"      -- picker: currently-broadcasting RT reactors not yet in
--                    the list. Tapping one starts editing it directly.
--   "edit"       -- form for ONE reactor (u.editing): inlet + thresholds
--                    inline, path as a one-line summary (tap to open
--                    "path"). FERTIG commits the working copy into
--                    u.reactors (still only in memory -- SPEICHERN on the
--                    list screen is the only thing that writes to disk).
--   "path"       -- valve chain editor for u.editing, unchanged in spirit
--                    from the previous implementation: tap known VALVE-Nodes
--                    to append, tap a chain step to remove, or teach-in by
--                    walking the pipe and toggling each valve's redstone
--                    lever. Returns to "edit", not "list".
--   "inlet_pick" -- list of peripherals currently visible to this computer;
--                    tapping one sets u.editing.inlet. Returns to "edit".

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")
local redstone_router_lib = require("nodes.fuel.redstone_router")

local DEFAULT_REACTORS_CONFIG_PATH = "/xreactor_config/fuel_routes.lua"

local STEP_RATIO = 0.05
local STEP_AMOUNT = 8
local VALVE_LABEL_MAX = 18

local function nonempty_string(v) return type(v) == "string" and v ~= "" end

local function clamp(value, lo, hi)
  if value < lo then return lo end
  if value > hi then return hi end
  return value
end

local function deep_copy_path(path)
  local out = {}
  for i, id in ipairs(path or {}) do out[i] = id end
  return out
end

local function copy_reactor(entry)
  return {
    reactor_id = entry.reactor_id,
    label = entry.label,
    inlet = entry.inlet,
    path = deep_copy_path(entry.path),
    request_below = entry.request_below or 0.25,
    fill_amount = entry.fill_amount or 64,
    min_in_me = entry.min_in_me or 32,
  }
end

-- ---- persistence ------------------------------------------------------------

local function load_reactors(path)
  if type(fs) ~= "table" then return {} end
  if not fs.exists(path) then return {} end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then return result end
  return {}
end

local function write_reactors_file(reactors, path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local ok_open, f = pcall(fs.open, path, "w")
  if not ok_open or not f then return false end
  f.writeLine("-- Fuel reactor configuration -- auto-generated, do not edit manually")
  f.writeLine("return {")
  for _, r in ipairs(reactors) do
    f.writeLine("  {")
    f.writeLine(string.format("    reactor_id = %q,", r.reactor_id or ""))
    f.writeLine(string.format("    label = %q,", r.label or r.reactor_id or ""))
    f.writeLine(string.format("    inlet = %q,", r.inlet or ""))
    f.writeLine(string.format("    request_below = %s,", tostring(tonumber(r.request_below) or 0.25)))
    f.writeLine(string.format("    fill_amount = %s,", tostring(tonumber(r.fill_amount) or 64)))
    f.writeLine(string.format("    min_in_me = %s,", tostring(tonumber(r.min_in_me) or 32)))
    f.writeLine("    path = {")
    for _, id in ipairs(r.path or {}) do
      f.writeLine(string.format("      %q,", id))
    end
    f.writeLine("    },")
    f.writeLine("  },")
  end
  f.writeLine("}")
  f.close()
  return true
end

-- Atomarer Schreibablauf -- unveraendert gegenueber der vorigen Implementierung
-- (siehe deren Kommentar): .tmp schreiben+validieren, alte Datei nach .prev
-- sichern, .tmp an Zielposition verschieben, final erneut lesen+validieren,
-- .prev erst nach vollem Erfolg loeschen; jeder Fehlschlag stellt die letzte
-- bekannt gute Datei wieder her bzw. laesst sie unangetastet.
local function save_reactors_atomic(reactors, path, validate_fn)
  local tmp_path = path .. ".tmp"
  local prev_path = path .. ".prev"

  if not write_reactors_file(reactors, tmp_path) then
    pcall(fs.delete, tmp_path)
    return false, "TMP_WRITE_FAILED", "Konnte " .. tmp_path .. " nicht schreiben"
  end

  local ok_load, tmp_content = pcall(dofile, tmp_path)
  if not ok_load or type(tmp_content) ~= "table" then
    pcall(fs.delete, tmp_path)
    return false, "TMP_READ_FAILED", "Frisch geschriebene .tmp-Datei liess sich nicht laden: " .. tostring(tmp_content)
  end
  if validate_fn then
    local ok_valid, verr = validate_fn(tmp_content)
    if not ok_valid then
      pcall(fs.delete, tmp_path)
      return false, "TMP_VALIDATE_FAILED", tostring(verr or "Validierung der .tmp-Datei fehlgeschlagen")
    end
  end

  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(prev_path) then pcall(fs.delete, prev_path) end
    local ok_bak = pcall(fs.move, path, prev_path)
    if not ok_bak then
      pcall(fs.delete, tmp_path)
      return false, "BACKUP_FAILED", "Konnte bestehende Datei nicht nach " .. prev_path .. " sichern"
    end
  end

  local ok_move = pcall(fs.move, tmp_path, path)
  if not ok_move then
    if had_old and fs.exists(prev_path) and not fs.exists(path) then
      pcall(fs.move, prev_path, path)
    end
    pcall(fs.delete, tmp_path)
    return false, "MOVE_FAILED", "Konnte .tmp nicht nach " .. path .. " verschieben"
  end

  local ok_final, final_content = pcall(dofile, path)
  if not ok_final or type(final_content) ~= "table" then
    if had_old and fs.exists(prev_path) then
      pcall(fs.delete, path)
      pcall(fs.move, prev_path, path)
    end
    return false, "FINAL_READ_FAILED", "Finale Datei liess sich nach dem Schreiben nicht laden: " .. tostring(final_content)
  end
  if validate_fn then
    local ok_valid2, verr2 = validate_fn(final_content)
    if not ok_valid2 then
      if had_old and fs.exists(prev_path) then
        pcall(fs.delete, path)
        pcall(fs.move, prev_path, path)
      end
      return false, "FINAL_VALIDATE_FAILED", tostring(verr2 or "Validierung der finalen Datei fehlgeschlagen")
    end
  end

  if had_old and fs.exists(prev_path) then pcall(fs.delete, prev_path) end
  return true
end

local function validate_reactors(reactors)
  if type(reactors) ~= "table" then return false, "kein Tabellen-Ergebnis" end
  for i, r in ipairs(reactors) do
    if type(r) ~= "table" then return false, "Eintrag " .. i .. " ist keine Tabelle" end
    if not nonempty_string(r.reactor_id) then return false, "Eintrag " .. i .. " hat keine reactor_id" end
    if r.path ~= nil and type(r.path) ~= "table" then return false, "Eintrag " .. i .. " hat einen ungueltigen Pfad" end
  end
  return true
end

-- ---- valve helpers (unveraendert aus der vorigen Implementierung) ----------

local function short_valve_label(id, label)
  label = (type(label) == "string" and label ~= "") and label or id
  return mux.fit(tostring(label), VALVE_LABEL_MAX)
end

-- Returns { { id=, label= }, ... }, sorted by id.
local function known_valve_ids(router)
  local out = {}
  if not router or not router.comms then return out end
  local ok, peers = pcall(router.comms.get_peers, router.comms)
  if not ok or type(peers) ~= "table" then return out end
  for id, data in pairs(peers) do
    if type(data) == "table" and data.down ~= true and data.role == constants.roles.VALVE_NODE then
      out[#out + 1] = { id = id, label = short_valve_label(id, data.label) }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

local function valve_display_label(router, id)
  for _, valve in ipairs(known_valve_ids(router)) do
    if valve.id == id then return valve.label end
  end
  return tostring(id)
end

local function path_text(router, path)
  if not path or #path == 0 then return "KEIN VENTIL" end
  local parts = {}
  for _, id in ipairs(path) do parts[#parts + 1] = valve_display_label(router, id) end
  return table.concat(parts, " > ")
end

-- ---- reactor-learn helpers --------------------------------------------------

-- Reactors currently broadcasting on the network (per self.get_reactors(),
-- the same live union reactor_targets.lua already builds from RT status
-- broadcasts) that are not yet in u.reactors -- candidates for EINLERNEN.
local function learnable_reactors(self)
  local known = {}
  for _, r in ipairs(self._ui.reactors) do
    if r.reactor_id then known[r.reactor_id] = true end
  end
  local out = {}
  for _, candidate in ipairs(self.get_reactors()) do
    if candidate.id and not known[candidate.id] then
      out[#out + 1] = candidate
    end
  end
  return out
end

-- Peripherals currently visible to this computer -- inlet picker source.
-- Monitors and modems are excluded: neither is ever a valid fuel inlet.
local EXCLUDED_INLET_TYPES = { monitor = true, modem = true }
local function known_peripheral_names()
  local out = {}
  for _, name in ipairs(peripheral.getNames() or {}) do
    local kind = peripheral.getType(name)
    if not EXCLUDED_INLET_TYPES[kind] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function clamp_scroll(value, total, visible)
  visible = math.max(1, tonumber(visible) or 1)
  local max_scroll = math.max(0, (tonumber(total) or 0) - visible)
  return math.max(0, math.min(tonumber(value) or 0, max_scroll)), max_scroll
end

local function paging_badges(target, w, y, scroll, max_scroll)
  if max_scroll <= 0 then return nil, nil end
  local up_x = math.max(2, w - 11)
  local down_x = math.max(7, w - 5)
  mux.badge(target, up_x, y, "UP", scroll > 0 and "LIMITED" or "OFFLINE")
  mux.badge(target, down_x, y, "DN", scroll < max_scroll and "LIMITED" or "OFFLINE")
  local up = scroll > 0 and { x1 = up_x, x2 = up_x + 3, y = y } or nil
  local down = scroll < max_scroll and { x1 = down_x, x2 = down_x + 3, y = y } or nil
  return up, down
end

-- A stepper row: label + current value, with "-"/"+" tap zones at the row's
-- tail. Used for the three per-reactor numeric thresholds -- no on-screen
-- keyboard exists on a CC:Tweaked touch monitor, so every number here is
-- adjusted by repeated taps rather than typed.
local function stepper_row(target, x, y, w, label, value_text, status)
  local minus_x = x + w - 7
  local plus_x = x + w - 3
  mux.data_row(target, x, y, math.max(1, w - 8), { label = label, value = value_text, status = status or "text", icon = "config" })
  mux.badge(target, minus_x, y, "-", "LIMITED")
  mux.badge(target, plus_x, y, "+", "LIMITED")
  return { x1 = minus_x, x2 = minus_x + 2, y = y }, { x1 = plus_x, x2 = plus_x + 2, y = y }
end

-- ---- constructor -------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config,
    redstone_router = opts.redstone_router,
    logistics_router = opts.logistics_router,
    log = opts.log or function() end,
    get_reactors = opts.get_reactors or function() return {} end,
    config_path = opts.config_path or DEFAULT_REACTORS_CONFIG_PATH,
    routing_load_status = opts.routing_load_status,
    _ui = {
      mode = "list",
      reactors = {},
      dirty = false,
      list_scroll = 0, list_scroll_up = nil, list_scroll_down = nil,
      reactor_btns = {}, learn_btn = nil, save_btn = nil, reset_btn = nil,
      -- "learn" state
      learn_scroll = 0, learn_scroll_up = nil, learn_scroll_down = nil,
      learn_btns = {}, learn_cancel_btn = nil,
      -- "edit" state (u.editing is the working copy; nil <=> not editing)
      editing = nil, editing_is_new = false,
      inlet_row = nil, path_row = nil,
      request_below_minus = nil, request_below_plus = nil,
      fill_amount_minus = nil, fill_amount_plus = nil,
      min_in_me_minus = nil, min_in_me_plus = nil,
      edit_done_btn = nil, edit_cancel_btn = nil, edit_delete_btn = nil,
      -- "inlet_pick" state
      inlet_scroll = 0, inlet_scroll_up = nil, inlet_scroll_down = nil,
      inlet_btns = {}, inlet_cancel_btn = nil,
      -- "path" state (unveraendert aus der vorigen Implementierung)
      path_scroll = 0, path_scroll_up = nil, path_scroll_down = nil,
      picker_scroll = 0, picker_scroll_up = nil, picker_scroll_down = nil,
      step_btns = {}, integrator_btns = {},
      path_done_btn = nil, path_cancel_btn = nil, path_clear_btn = nil,
      teaching = false, teach_btn = nil,
      save = { state = "IDLE", error = nil, saved_at = nil },
    },
  }
  setmetatable(self, { __index = M })

  -- config.logistics.reactors ist die kanonische Quelle waehrend der
  -- Laufzeit (main.lua laedt die persistierte Datei dort schon vor dem
  -- ersten config_normalizer.normalize()-Durchlauf hinein). Faellt kein
  -- config vor, wird als naechstes die Config des uebergebenen
  -- redstone_router probiert (gleiches Muster wie vorher) -- die Datei
  -- selbst wird nur gelesen, wenn wirklich keine der beiden vorliegt
  -- (z.B. minimal aufgebaute Tests ohne fs-Umgebung).
  local cfg = self.config
  local lg = cfg and (cfg.logistics or cfg) or nil
  local rr_cfg = self.redstone_router and self.redstone_router.config
  local rr_lg = rr_cfg and (rr_cfg.logistics or rr_cfg) or nil
  local source = (lg and lg.reactors) or (rr_lg and rr_lg.reactors) or load_reactors(self.config_path)
  for _, entry in ipairs(source) do
    self._ui.reactors[#self._ui.reactors + 1] = copy_reactor(entry)
  end
  return self
end

function M:_find_reactor(reactor_id)
  for _, r in ipairs(self._ui.reactors) do
    if r.reactor_id == reactor_id then return r end
  end
end

-- ---- render: list ------------------------------------------------------------

function M:_render_list(target, w, h)
  local u = self._ui
  local configured, incomplete = 0, 0
  for _, r in ipairs(u.reactors) do
    if r.inlet and r.path and #r.path > 0 then configured = configured + 1 else incomplete = incomplete + 1 end
  end
  mux.status_dot(target, 2, 3, string.format("REAKTOREN %d/%d BEREIT", configured, #u.reactors),
    incomplete == 0 and #u.reactors > 0 and "OK" or "LIMITED", math.max(8, math.floor(w * 0.4)))

  if w >= 40 then
    local save_label, save_key
    if self.routing_load_status and self.routing_load_status.ok == false then
      save_label, save_key = "ROUTING INVALID: " .. mux.fit(tostring(self.routing_load_status.message or self.routing_load_status.code or "?"), 20), "WARNING"
    elseif u.save.state == "FAILED" then
      save_label, save_key = "FEHLER: " .. mux.fit(tostring(u.save.error or "?"), 24), "WARNING"
    elseif u.save.state == "SAVING" then
      save_label, save_key = "WIRD GESPEICHERT...", "LIMITED"
    elseif u.dirty then
      save_label, save_key = "UNGESPEICHERT", "LIMITED"
    else
      save_label, save_key = "GESPEICHERT=AKTIV", "OK"
    end
    mux.status_dot(target, math.floor(w * 0.42), 3, save_label, save_key, math.max(1, w - math.floor(w * 0.42) - 2))
  end

  local learn_lbl = "REAKTOR EINLERNEN"
  if w < 34 then learn_lbl = "EINLERNEN" end
  u.learn_btn = mux.button(target, 2, 4, w - 3, learn_lbl, "LIMITED", 1)

  local body_top = 6
  local button_y = math.max(body_top + 3, h - 2)
  local body_bottom = math.max(body_top + 2, button_y - 1)
  local body_h = body_bottom - body_top + 1
  mux.card(target, 2, body_top, w - 3, body_h, { title = "REAKTOREN -- ANTIPPEN ZUM BEARBEITEN", status = #u.reactors > 0 and "OK" or "WARNING", icon = "reactor" })

  local first_y = body_top + 2
  local control_y = body_top + body_h - 1
  local visible = math.max(1, control_y - first_y)
  local max_scroll
  u.list_scroll, max_scroll = clamp_scroll(u.list_scroll, #u.reactors, visible)

  local reactor_btns = {}
  local y = first_y
  for i = u.list_scroll + 1, math.min(#u.reactors, u.list_scroll + visible) do
    local r = u.reactors[i]
    local status = (r.inlet and r.path and #r.path > 0) and "OK" or "LIMITED"
    local summary = string.format("%s | %s%%/%d/%d",
      r.inlet and mux.fit(r.inlet, 14) or "KEIN INLET",
      tostring(math.floor((r.request_below or 0.25) * 100)),
      math.floor(r.fill_amount or 64), math.floor(r.min_in_me or 32))
    mux.data_row(target, 4, y, w - 6, { label = tostring(r.label or r.reactor_id), value = mux.fit(summary, math.max(1, w - 6 - #tostring(r.label or r.reactor_id) - 2)), status = status, icon = "reactor" })
    reactor_btns[#reactor_btns + 1] = { x1 = 4, x2 = w - 3, y = y, reactor_id = r.reactor_id }
    y = y + 1
  end
  u.reactor_btns = reactor_btns

  if #u.reactors == 0 and first_y <= control_y then
    mux.warning_box(target, 4, first_y, w - 6,
      { "Keine Reaktoren konfiguriert", "REAKTOR EINLERNEN antippen" }, "WARNING")
  end

  if max_scroll > 0 then
    mux.text(target, 4, control_y,
      string.format("%d-%d/%d", u.list_scroll + 1, math.min(#u.reactors, u.list_scroll + visible), #u.reactors),
      colorset.get("muted"), colorset.get("background"))
    u.list_scroll_up, u.list_scroll_down = paging_badges(target, w - 2, control_y, u.list_scroll, max_scroll)
  else
    u.list_scroll_up, u.list_scroll_down = nil, nil
  end

  local save_lbl = u.dirty and "SPEICHERN *" or "SPEICHERN"
  local reset_lbl = "RESET"
  if w < 34 then save_lbl, reset_lbl = u.dirty and "SAVE*" or "SAVE", "RST" end
  local total_w = w - 3
  local reset_w = math.min(math.max(#reset_lbl + 2, 8), math.floor(total_w * 0.35))
  local save_w = math.max(1, total_w - reset_w - 1)
  u.save_btn = mux.button(target, 2, button_y - 1, save_w, save_lbl, u.dirty and "LIMITED" or "OK", 2)
  u.reset_btn = mux.button(target, 2 + save_w + 1, button_y - 1, reset_w, reset_lbl, "OFFLINE", 2)
end

-- ---- render: learn ------------------------------------------------------------

function M:_render_learn(target, w, h)
  local u = self._ui
  local candidates = learnable_reactors(self)
  mux.banner(target, 2, 3, w - 3, "REAKTOR EINLERNEN -- AKTIVE RT-MELDUNGEN", "LIMITED", "reactor")

  local body_top = 5
  local button_y = math.max(body_top + 3, h - 2)
  local body_h = math.max(3, button_y - 1 - body_top + 1)
  mux.card(target, 2, body_top, w - 3, body_h, { title = "GEFUNDENE REAKTOREN", status = #candidates > 0 and "OK" or "WARNING", icon = "network" })

  local first_y = body_top + 1
  local visible = math.max(1, body_h - 1)
  local max_scroll
  u.learn_scroll, max_scroll = clamp_scroll(u.learn_scroll, #candidates, visible)
  u.learn_scroll_up, u.learn_scroll_down = paging_badges(target, w - 2, body_top, u.learn_scroll, max_scroll)

  local learn_btns = {}
  local y = first_y
  for i = u.learn_scroll + 1, math.min(#candidates, u.learn_scroll + visible) do
    local c = candidates[i]
    mux.data_row(target, 4, y, w - 6, { label = tostring(c.label or c.id), value = "EINLERNEN", status = "OK", icon = "reactor" })
    learn_btns[#learn_btns + 1] = { x1 = 4, x2 = w - 3, y = y, id = c.id, label = c.label }
    y = y + 1
  end
  u.learn_btns = learn_btns

  if #candidates == 0 and first_y <= button_y - 1 then
    mux.text(target, 4, first_y, mux.fit("(keine unbekannten Reaktoren per Funk erreichbar)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end

  u.learn_cancel_btn = mux.button(target, 2, button_y - 1, w - 3, "ABBRECHEN", "WARNING", 2)
end

-- ---- render: edit (per reactor form) ------------------------------------------

function M:_render_edit(target, w, h)
  local u = self._ui
  local editing = u.editing
  if not editing then u.mode = "list"; return self:_render_list(target, w, h) end

  mux.banner(target, 2, 3, w - 3, "REAKTOR: " .. tostring(editing.label or editing.reactor_id), "LIMITED", "reactor")

  local body_top = 5
  local button_y = math.max(body_top + 6, h - 2)
  local rows_bottom = button_y - 1
  mux.card(target, 2, body_top, w - 3, rows_bottom - body_top + 1, { title = "EINSTELLUNGEN", status = "LIMITED", icon = "config" })

  local y = body_top + 1
  mux.data_row(target, 4, y, w - 6, { label = "INLET", value = editing.inlet and mux.fit(editing.inlet, w - 6 - 10) or "NICHT GESETZT", status = editing.inlet and "OK" or "WARNING", icon = "output" })
  u.inlet_row = { x1 = 4, x2 = w - 3, y = y }
  y = y + 1

  mux.data_row(target, 4, y, w - 6, { label = "PFAD", value = mux.fit(path_text(self.redstone_router, editing.path), w - 6 - 10), status = (#editing.path > 0) and "OK" or "WARNING", icon = "network" })
  u.path_row = { x1 = 4, x2 = w - 3, y = y }
  y = y + 1

  u.request_below_minus, u.request_below_plus = stepper_row(target, 4, y, w - 6,
    "SCHWELLE", string.format("%d%%", math.floor((editing.request_below or 0.25) * 100)))
  y = y + 1

  u.fill_amount_minus, u.fill_amount_plus = stepper_row(target, 4, y, w - 6,
    "MENGE", tostring(math.floor(editing.fill_amount or 64)))
  y = y + 1

  u.min_in_me_minus, u.min_in_me_plus = stepper_row(target, 4, y, w - 6,
    "MIN-ME", tostring(math.floor(editing.min_in_me or 32)))

  local done_lbl, delete_lbl, cancel_lbl = "FERTIG", "LOESCHEN", "ABBRECHEN"
  if w < 50 then done_lbl, delete_lbl, cancel_lbl = "OK", "DEL", "X" end
  local total_w = w - 3
  local done_w = math.max(#done_lbl + 2, math.floor(total_w * 0.36))
  local cancel_w = math.max(#cancel_lbl + 2, math.floor(total_w * 0.30))
  local delete_w = math.max(1, total_w - done_w - cancel_w - 2)
  u.edit_done_btn = mux.button(target, 2, button_y - 1, done_w, done_lbl, "OK", 2)
  u.edit_delete_btn = mux.button(target, 2 + done_w + 1, button_y - 1, delete_w, delete_lbl, "WARNING", 2)
  u.edit_cancel_btn = mux.button(target, 2 + done_w + delete_w + 2, button_y - 1, cancel_w, cancel_lbl, "OFFLINE", 2)
end

-- ---- render: inlet picker ------------------------------------------------------

function M:_render_inlet_pick(target, w, h)
  local u = self._ui
  local names = known_peripheral_names()
  mux.banner(target, 2, 3, w - 3, "INLET WAEHLEN", "LIMITED", "output")

  local body_top = 5
  local button_y = math.max(body_top + 3, h - 2)
  local body_h = math.max(3, button_y - 1 - body_top + 1)
  mux.card(target, 2, body_top, w - 3, body_h, { title = "ERKANNTE PERIPHERALS", status = #names > 0 and "OK" or "WARNING", icon = "network" })

  local first_y = body_top + 1
  local visible = math.max(1, body_h - 1)
  local max_scroll
  u.inlet_scroll, max_scroll = clamp_scroll(u.inlet_scroll, #names, visible)
  u.inlet_scroll_up, u.inlet_scroll_down = paging_badges(target, w - 2, body_top, u.inlet_scroll, max_scroll)

  local inlet_btns = {}
  local y = first_y
  for i = u.inlet_scroll + 1, math.min(#names, u.inlet_scroll + visible) do
    local name = names[i]
    mux.data_row(target, 4, y, w - 6, { label = name, value = "WAEHLEN", status = "OK", icon = "output" })
    inlet_btns[#inlet_btns + 1] = { x1 = 4, x2 = w - 3, y = y, name = name }
    y = y + 1
  end
  u.inlet_btns = inlet_btns

  if #names == 0 and first_y <= button_y - 1 then
    mux.text(target, 4, first_y, mux.fit("(keine Peripherals erkannt)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end

  u.inlet_cancel_btn = mux.button(target, 2, button_y - 1, w - 3, "ABBRECHEN", "WARNING", 2)
end

-- ---- render: path editor (unveraendert aus der vorigen Implementierung) ------

function M:_render_path(target, w, h)
  local u = self._ui
  local editing = u.editing
  if not editing then u.mode = "list"; return self:_render_list(target, w, h) end

  mux.banner(target, 2, 3, w - 3, "VENTILKETTE: " .. tostring(editing.label or editing.reactor_id), "LIMITED", "reactor")

  local teach_lbl = u.teaching and "EINLERNEN: AN -- Hebel am Ventil umlegen" or "EINLERNEN: AUS -- antippen zum Aktivieren"
  if w < 60 then
    teach_lbl = u.teaching and "EINLERNEN: AN (Hebel umlegen)" or "EINLERNEN: AUS (antippen)"
  end
  if w < 40 then
    teach_lbl = u.teaching and "TEACH: AN" or "TEACH: AUS"
  end
  u.teach_btn = mux.button(target, 2, 4, w - 3, teach_lbl, u.teaching and "OK" or "LIMITED", 1)

  local button_y = math.max(7, h - 2)
  local content_top = 5
  local content_bottom = math.max(content_top + 3, button_y - 1)
  local total_body = math.max(4, content_bottom - content_top + 1)
  local chain_h = math.max(2, math.min(7, math.floor(total_body * 0.45)))
  if total_body - chain_h < 2 then chain_h = math.max(2, total_body - 2) end
  local picker_top = content_top + chain_h
  local picker_h = math.max(2, content_bottom - picker_top + 1)

  mux.card(target, 2, content_top, w - 3, chain_h, { title = "AKTUELLE KETTE", status = #editing.path > 0 and "OK" or "LIMITED", icon = "network" })
  local visible_steps = math.max(1, chain_h - 1)
  local path_max_scroll
  u.path_scroll, path_max_scroll = clamp_scroll(u.path_scroll, #editing.path, visible_steps)
  u.path_scroll_up, u.path_scroll_down = paging_badges(target, w - 2, content_top, u.path_scroll, path_max_scroll)

  local step_btns = {}
  local sy = content_top + 1
  for i = u.path_scroll + 1, math.min(#editing.path, u.path_scroll + visible_steps) do
    local id = editing.path[i]
    mux.data_row(target, 4, sy, w - 6, { label = tostring(i) .. ".", value = valve_display_label(self.redstone_router, id), status = "OK", icon = "output" })
    step_btns[#step_btns + 1] = { x1 = 4, x2 = w - 3, y = sy, index = i }
    sy = sy + 1
  end
  if #editing.path == 0 and sy <= content_top + chain_h - 1 then
    mux.text(target, 4, sy, mux.fit("(noch kein Ventil)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end
  u.step_btns = step_btns

  local integrator_btns = {}
  local items = known_valve_ids(self.redstone_router)
  mux.card(target, 2, picker_top, w - 3, picker_h, { title = "VENTIL ANFUEGEN (VALVE-NODE WAEHLEN)", status = "LIMITED", icon = "output" })

  local visible_picker = math.max(1, picker_h - 1)
  local picker_max_scroll
  u.picker_scroll, picker_max_scroll = clamp_scroll(u.picker_scroll, #items, visible_picker)
  u.picker_scroll_up, u.picker_scroll_down = paging_badges(target, w - 2, picker_top, u.picker_scroll, picker_max_scroll)
  local picker_y = picker_top + 1
  for i = u.picker_scroll + 1, math.min(#items, u.picker_scroll + visible_picker) do
    local item = items[i]
    mux.data_row(target, 4, picker_y, w - 6, { label = item.label, value = "ANTIPPEN", status = "OK", icon = "network" })
    integrator_btns[#integrator_btns + 1] = { x1 = 4, x2 = w - 3, y = picker_y, integrator = item.id }
    picker_y = picker_y + 1
  end
  if #items == 0 and picker_y <= picker_top + picker_h - 1 then
    mux.text(target, 4, picker_y, mux.fit("(keine VALVE-Nodes per Funk erreichbar)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end
  u.integrator_btns = integrator_btns

  local done_lbl, clear_lbl, cancel_lbl = "FERTIG", "LEEREN", "ABBRECHEN"
  if w < 40 then done_lbl, clear_lbl, cancel_lbl = "OK", "CLR", "X" end
  local total_w = w - 3
  local done_w = math.max(#done_lbl + 2, math.floor(total_w * 0.36))
  local cancel_w = math.max(#cancel_lbl + 2, math.floor(total_w * 0.30))
  local clear_w = math.max(1, total_w - done_w - cancel_w - 2)
  u.path_done_btn = mux.button(target, 2, button_y - 1, done_w, done_lbl, "OK", 2)
  u.path_clear_btn = mux.button(target, 2 + done_w + 1, button_y - 1, clear_w, clear_lbl, "LIMITED", 2)
  u.path_cancel_btn = mux.button(target, 2 + done_w + clear_w + 2, button_y - 1, cancel_w, cancel_lbl, "WARNING", 2)
end

-- ---- top-level render ---------------------------------------------------------

function M:render(target, ui, colors, should_clear)
  if should_clear == nil then should_clear = false end
  local w, h = ui.getSize(target)
  if not w or not h then
    local ok, fw, fh = pcall(function() return target.getSize() end)
    if ok and fw and fh then w, h = fw, fh else return end
  end
  local u = self._ui
  local page_status = u.save.state == "FAILED" and "WARNING" or (u.dirty and "LIMITED" or "OK")
  if should_clear then mux.clear(target) end
  mux.header(target, { title = "FUEL ROUTER", node_id = "FUEL NODE", page = "4/4", status = page_status, icon = "network" })

  local footer_center
  if u.mode == "learn" then
    self:_render_learn(target, w, h); footer_center = "REAKTOR EINLERNEN"
  elseif u.mode == "edit" then
    self:_render_edit(target, w, h); footer_center = "REAKTOR BEARBEITEN"
  elseif u.mode == "inlet_pick" then
    self:_render_inlet_pick(target, w, h); footer_center = "INLET WAEHLEN"
  elseif u.mode == "path" then
    self:_render_path(target, w, h); footer_center = "VENTILKETTE"
  else
    self:_render_list(target, w, h); footer_center = "FUEL ROUTER"
  end
  return mux.footer_nav(target, h, w, { center = footer_center, inset = 3 })
end

-- ---- touch handling -------------------------------------------------------------

local function hit(b, x, y)
  return b and y >= b.y and y <= (b.y2 or b.y) and x >= b.x1 and x <= b.x2
end

function M:_handle_list_touch(x, y)
  local u = self._ui
  if hit(u.list_scroll_up, x, y) then u.list_scroll = math.max(0, u.list_scroll - 1); return true end
  if hit(u.list_scroll_down, x, y) then u.list_scroll = u.list_scroll + 1; return true end
  if hit(u.learn_btn, x, y) then
    u.mode = "learn"
    u.learn_scroll = 0
    return true
  end
  if hit(u.save_btn, x, y) then self:_do_save(); return true end
  if hit(u.reset_btn, x, y) then
    local cfg = self.config
    local lg = cfg and (cfg.logistics or cfg) or nil
    u.reactors = {}
    for _, entry in ipairs((lg and lg.reactors) or {}) do
      u.reactors[#u.reactors + 1] = copy_reactor(entry)
    end
    u.dirty = false
    u.save.state = "IDLE"
    u.save.error = nil
    return true
  end
  for _, btn in ipairs(u.reactor_btns or {}) do
    if hit(btn, x, y) then
      local existing = self:_find_reactor(btn.reactor_id)
      if existing then
        u.editing = copy_reactor(existing)
        u.editing_is_new = false
        u.mode = "edit"
        return true
      end
    end
  end
  return false
end

function M:_handle_learn_touch(x, y)
  local u = self._ui
  if hit(u.learn_scroll_up, x, y) then u.learn_scroll = math.max(0, u.learn_scroll - 1); return true end
  if hit(u.learn_scroll_down, x, y) then u.learn_scroll = u.learn_scroll + 1; return true end
  if hit(u.learn_cancel_btn, x, y) then
    u.mode = "list"
    return true
  end
  for _, btn in ipairs(u.learn_btns or {}) do
    if hit(btn, x, y) then
      u.editing = { reactor_id = btn.id, label = btn.label, inlet = nil, path = {},
        request_below = 0.25, fill_amount = 64, min_in_me = 32 }
      u.editing_is_new = true
      u.mode = "edit"
      return true
    end
  end
  return false
end

function M:_handle_edit_touch(x, y)
  local u = self._ui
  local editing = u.editing
  if not editing then u.mode = "list"; return false end

  if hit(u.inlet_row, x, y) then
    u.mode = "inlet_pick"
    u.inlet_scroll = 0
    return true
  end
  if hit(u.path_row, x, y) then
    u.mode = "path"
    u.path_scroll, u.picker_scroll = 0, 0
    return true
  end
  if hit(u.request_below_minus, x, y) then editing.request_below = clamp((editing.request_below or 0.25) - STEP_RATIO, 0, 1); return true end
  if hit(u.request_below_plus, x, y) then editing.request_below = clamp((editing.request_below or 0.25) + STEP_RATIO, 0, 1); return true end
  if hit(u.fill_amount_minus, x, y) then editing.fill_amount = math.max(STEP_AMOUNT, (editing.fill_amount or 64) - STEP_AMOUNT); return true end
  if hit(u.fill_amount_plus, x, y) then editing.fill_amount = (editing.fill_amount or 64) + STEP_AMOUNT; return true end
  if hit(u.min_in_me_minus, x, y) then editing.min_in_me = math.max(0, (editing.min_in_me or 32) - STEP_AMOUNT); return true end
  if hit(u.min_in_me_plus, x, y) then editing.min_in_me = (editing.min_in_me or 32) + STEP_AMOUNT; return true end

  if hit(u.edit_done_btn, x, y) then
    local new_reactors = {}
    for _, r in ipairs(u.reactors) do
      if r.reactor_id ~= editing.reactor_id then new_reactors[#new_reactors + 1] = r end
    end
    new_reactors[#new_reactors + 1] = copy_reactor(editing)
    u.reactors = new_reactors
    u.dirty = true
    u.editing = nil
    u.mode = "list"
    return true
  end
  if hit(u.edit_delete_btn, x, y) then
    local new_reactors = {}
    for _, r in ipairs(u.reactors) do
      if r.reactor_id ~= editing.reactor_id then new_reactors[#new_reactors + 1] = r end
    end
    u.reactors = new_reactors
    u.dirty = true
    u.editing = nil
    u.mode = "list"
    return true
  end
  if hit(u.edit_cancel_btn, x, y) then
    u.editing = nil
    u.mode = "list"
    return true
  end
  return false
end

function M:_handle_inlet_pick_touch(x, y)
  local u = self._ui
  if hit(u.inlet_scroll_up, x, y) then u.inlet_scroll = math.max(0, u.inlet_scroll - 1); return true end
  if hit(u.inlet_scroll_down, x, y) then u.inlet_scroll = u.inlet_scroll + 1; return true end
  if hit(u.inlet_cancel_btn, x, y) then
    u.mode = "edit"
    return true
  end
  for _, btn in ipairs(u.inlet_btns or {}) do
    if hit(btn, x, y) then
      if u.editing then u.editing.inlet = btn.name end
      u.mode = "edit"
      return true
    end
  end
  return false
end

function M:_handle_path_touch(x, y)
  local u = self._ui
  if hit(u.path_scroll_up, x, y) then u.path_scroll = math.max(0, u.path_scroll - 1); return true end
  if hit(u.path_scroll_down, x, y) then u.path_scroll = u.path_scroll + 1; return true end
  if hit(u.picker_scroll_up, x, y) then u.picker_scroll = math.max(0, u.picker_scroll - 1); return true end
  if hit(u.picker_scroll_down, x, y) then u.picker_scroll = u.picker_scroll + 1; return true end
  if hit(u.teach_btn, x, y) then u.teaching = not u.teaching; return true end
  if hit(u.path_cancel_btn, x, y) then
    u.teaching = false
    u.mode = "edit"
    u.picker_scroll = 0
    return true
  end
  if hit(u.path_done_btn, x, y) then
    -- Committed straight into the (still in-memory) editing copy -- the
    -- outer "edit" form's own FERTIG is what merges it into u.reactors.
    u.teaching = false
    u.mode = "edit"
    u.picker_scroll = 0
    return true
  end
  if hit(u.path_clear_btn, x, y) then
    if u.editing then u.editing.path = {} end
    u.path_scroll, u.picker_scroll = 0, 0
    return true
  end
  for _, btn in ipairs(u.step_btns or {}) do
    if hit(btn, x, y) then
      if u.editing then table.remove(u.editing.path, btn.index) end
      return true
    end
  end
  for _, btn in ipairs(u.integrator_btns or {}) do
    if hit(btn, x, y) then
      if u.editing then u.editing.path[#u.editing.path + 1] = btn.integrator end
      return true
    end
  end
  return false
end

function M:handle_touch(x, y)
  local u = self._ui
  if u.mode == "learn" then return self:_handle_learn_touch(x, y) end
  if u.mode == "edit" then return self:_handle_edit_touch(x, y) end
  if u.mode == "inlet_pick" then return self:_handle_inlet_pick_touch(x, y) end
  if u.mode == "path" then return self:_handle_path_touch(x, y) end
  return self:_handle_list_touch(x, y)
end

-- ---- persistence + valve teach-in --------------------------------------------

-- Speichert 1) atomar in die persistierte Datei, 2) uebernimmt bei Erfolg
-- die Arbeitskopie in config.logistics.reactors und stoesst
-- logistics_router:refresh_peripherals() an, damit Inlet-Bindung und die
-- daraus abgeleitete redstone_tree sofort aktuell sind.
function M:_do_save()
  local u = self._ui
  u.save.state = "SAVING"

  local snapshot = {}
  for _, r in ipairs(u.reactors) do snapshot[#snapshot + 1] = copy_reactor(r) end

  local ok_valid, verr = validate_reactors(snapshot)
  if not ok_valid then
    u.save.state = "FAILED"
    u.save.error = tostring(verr or "unbekannter Validierungsfehler")
    u.save.saved_at = nil
    self.log("WARN", "RouterUI: Speichern abgelehnt (Validierung fehlgeschlagen): " .. tostring(u.save.error))
    return false
  end

  local ok, err_code, err_msg = save_reactors_atomic(snapshot, self.config_path, function(content)
    return validate_reactors(content)
  end)
  if not ok then
    u.save.state = "FAILED"
    u.save.error = tostring(err_code) .. ": " .. tostring(err_msg)
    self.log("WARN", "RouterUI: atomarer Schreibvorgang fehlgeschlagen (" .. tostring(self.config_path) .. "): " .. tostring(err_code) .. " - " .. tostring(err_msg))
    return false
  end

  local cfg = self.config
  if cfg then
    local lg = cfg.logistics or cfg
    lg.reactors = snapshot
    if self.logistics_router then self.logistics_router:refresh_peripherals() end
  end

  u.dirty = false
  u.save.state = "SAVED"
  u.save.error = nil
  u.save.saved_at = os.epoch and os.epoch("utc") or nil
  self.log("INFO", "RouterUI: saved " .. #snapshot .. " reactors to " .. tostring(self.config_path))
  return true
end

-- "Weg 3"-Teach-in: der Spieler laeuft die physische Rohrleitung ab und legt
-- an jedem Ventil kurz einen Hebel um (siehe nodes/valve/main.lua's
-- check_teach_input()/ROUTE_TEACH_PULSE); die gemeldete Node wird in genau
-- dieser Reihenfolge an die Kette angehaengt, waehrend der Teach-Modus aktiv
-- ist.
function M:handle_teach_pulse(node_id)
  local u = self._ui
  if not node_id then return false end
  if u.mode ~= "path" or not u.editing or not u.teaching then return false end
  local last = u.editing.path[#u.editing.path]
  if last == node_id then return false end
  u.editing.path[#u.editing.path + 1] = node_id
  return true
end

return M
