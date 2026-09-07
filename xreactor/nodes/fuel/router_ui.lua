-- nodes/fuel/router_ui.lua
--
-- Single-screen FUEL reactor manager (2026-09-04 rewrite, export_chest
-- follow-up same day). Replaces the old TREE/EDIT tab pair (a hand-
-- maintained valve-route tree, loosely linked by matching string labels to
-- a separately hand-maintained reactor demand list) with ONE reactor list,
-- each entry carrying everything FUEL needs for that reactor: reactor_id/
-- label (learned from the owning RT node's own broadcasts, never typed by
-- hand), the valve path to it, and its resupply thresholds. There is no
-- `item` field anywhere -- logistics_router.lua decides Uranium vs
-- Blutonium and Ingot vs Block automatically on every delivery (see its
-- build_fuel_families()/pick_fuel_family()/pick_fuel_form()).
--
-- There is also no per-reactor delivery target: every reactor shares ONE
-- export chest (u.export_chest / config.logistics.export_chest), the sole
-- physical hand-off point FUEL exports fuel into. A Mekanism logistics
-- network (sorters + VALVE-Nodes) carries everything downstream from that
-- one chest; which reactor a delivery actually reaches is decided purely
-- by which valves are open at export time (see redstone_router.lua's
-- begin_transaction()). The export chest is therefore a page-level setting
-- (EXPORT-KISTE row on the main screen), not a per-reactor field.
--
-- u.mode (this page's only internal state machine):
--   "list"       -- the main screen: EXPORT-KISTE setting, every configured
--                    reactor (tap a row to edit it), EINLERNEN to add one
--                    from a live RT broadcast.
--   "learn"      -- picker: currently-broadcasting RT reactors not yet in
--                    the list. Tapping one starts editing it directly.
--   "edit"       -- form for ONE reactor (u.editing): thresholds inline,
--                    path as a one-line summary (tap to open "path").
--                    FERTIG commits the working copy into u.reactors
--                    (still only in memory -- SPEICHERN on the list screen
--                    is the only thing that writes to disk).
--   "path"       -- valve chain editor for u.editing, unchanged in spirit
--                    from the previous implementation: tap known VALVE-Nodes
--                    to append, tap a chain step to remove, or teach-in by
--                    walking the pipe and toggling each valve's redstone
--                    lever. Returns to "edit", not "list".
--   "chest_pick" -- list of peripherals currently visible to this computer;
--                    tapping one sets u.export_chest. Returns to "list"
--                    (unlike "path"/the old "inlet_pick", this is a
--                    page-level setting, not part of one reactor's working
--                    copy).

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")
local redstone_router_lib = require("nodes.fuel.redstone_router")
local router_scada = require("nodes.fuel.router_scada")

local DEFAULT_REACTORS_CONFIG_PATH = "/xreactor_config/fuel_routes.lua"

local STEP_RATIO = 0.05
local STEP_AMOUNT = 8
local STEP_COOLDOWN_S = 5
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
    path = deep_copy_path(entry.path),
    request_below = entry.request_below or 0.25,
    fill_amount = entry.fill_amount or 64,
    min_in_me = entry.min_in_me or 32,
    -- Abklingzeit nach einer Lieferung an diesen Reaktor, bevor erneut
    -- nachgelegt wird -- je nach physischer Entfernung vom Transportnetz
    -- unterschiedlich lang, siehe logistics_router.lua's record_export().
    resupply_cooldown_s = entry.resupply_cooldown_s or 30,
  }
end

-- ---- persistence ------------------------------------------------------------
--
-- Persisted shape: { export_chest = <peripheral name or nil>, reactors = {...} }
-- -- export_chest is a page-level setting (the ONE shared hand-off point,
-- see top-of-file comment), not a per-reactor field.

local function load_state(path)
  if type(fs) ~= "table" then return { export_chest = nil, reactors = {} } end
  if not fs.exists(path) then return { export_chest = nil, reactors = {} } end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then
    return { export_chest = result.export_chest, reactors = type(result.reactors) == "table" and result.reactors or {} }
  end
  return { export_chest = nil, reactors = {} }
end

local function write_state_file(state, path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local ok_open, f = pcall(fs.open, path, "w")
  if not ok_open or not f then return false end
  f.writeLine("-- Fuel reactor configuration -- auto-generated, do not edit manually")
  f.writeLine("return {")
  if nonempty_string(state.export_chest) then
    f.writeLine(string.format("  export_chest = %q,", state.export_chest))
  else
    f.writeLine("  export_chest = nil,")
  end
  f.writeLine("  reactors = {")
  for _, r in ipairs(state.reactors or {}) do
    f.writeLine("    {")
    f.writeLine(string.format("      reactor_id = %q,", r.reactor_id or ""))
    f.writeLine(string.format("      label = %q,", r.label or r.reactor_id or ""))
    f.writeLine(string.format("      request_below = %s,", tostring(tonumber(r.request_below) or 0.25)))
    f.writeLine(string.format("      fill_amount = %s,", tostring(tonumber(r.fill_amount) or 64)))
    f.writeLine(string.format("      min_in_me = %s,", tostring(tonumber(r.min_in_me) or 32)))
    f.writeLine(string.format("      resupply_cooldown_s = %s,", tostring(tonumber(r.resupply_cooldown_s) or 30)))
    f.writeLine("      path = {")
    for _, id in ipairs(r.path or {}) do
      f.writeLine(string.format("        %q,", id))
    end
    f.writeLine("      },")
    f.writeLine("    },")
  end
  f.writeLine("  },")
  f.writeLine("}")
  f.close()
  return true
end

-- Atomarer Schreibablauf -- unveraendert gegenueber der vorigen Implementierung
-- (siehe deren Kommentar): .tmp schreiben+validieren, alte Datei nach .prev
-- sichern, .tmp an Zielposition verschieben, final erneut lesen+validieren,
-- .prev erst nach vollem Erfolg loeschen; jeder Fehlschlag stellt die letzte
-- bekannt gute Datei wieder her bzw. laesst sie unangetastet.
local function save_state_atomic(state, path, validate_fn)
  local tmp_path = path .. ".tmp"
  local prev_path = path .. ".prev"

  if not write_state_file(state, tmp_path) then
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

local function validate_state(state)
  if type(state) ~= "table" then return false, "kein Tabellen-Ergebnis" end
  if state.export_chest ~= nil and not nonempty_string(state.export_chest) then
    return false, "export_chest ist gesetzt, aber leer/ungueltig"
  end
  if type(state.reactors) ~= "table" then return false, "reactors ist keine Tabelle" end
  for i, r in ipairs(state.reactors) do
    if type(r) ~= "table" then return false, "Eintrag " .. i .. " ist keine Tabelle" end
    if not nonempty_string(r.reactor_id) then return false, "Eintrag " .. i .. " hat keine reactor_id" end
    if r.path ~= nil and type(r.path) ~= "table" then return false, "Eintrag " .. i .. " hat einen ungueltigen Pfad" end
  end
  return true
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
    -- Persistiert logistics.enabled sofort in die Live-Config (nicht die
    -- fuel_routes.lua-Datei, die nur export_chest/reactors haelt) -- der
    -- Schalter wirkt sich unmittelbar aus, kein SPEICHERN/dirty-Batching
    -- wie bei Reaktoren/Export-Kiste, da es ein reiner Sicherheits-Toggle
    -- ist ("Nur aktivieren, wenn Hardware bereit ist", siehe config.lua).
    set_logistics_enabled = opts.set_logistics_enabled or function() end,
    _ui = {
      mode = "list",
      reactors = {},
      export_chest = nil,
      logistics_enabled = false,
      dirty = false,
      list_scroll = 0, list_scroll_up = nil, list_scroll_down = nil,
      reactor_btns = {}, learn_btn = nil, save_btn = nil, reset_btn = nil,
      export_chest_btn = nil, logistics_btn = nil,
      -- "learn" state
      learn_scroll = 0, learn_scroll_up = nil, learn_scroll_down = nil,
      learn_btns = {}, learn_cancel_btn = nil,
      -- "edit" state (u.editing is the working copy; nil <=> not editing)
      editing = nil, editing_is_new = false,
      path_row = nil,
      request_below_minus = nil, request_below_plus = nil,
      fill_amount_minus = nil, fill_amount_plus = nil,
      min_in_me_minus = nil, min_in_me_plus = nil,
      cooldown_minus = nil, cooldown_plus = nil,
      edit_done_btn = nil, edit_cancel_btn = nil, edit_delete_btn = nil,
      -- "chest_pick" state (sets u.export_chest, a page-level setting --
      -- returns to "list", not "edit")
      chest_scroll = 0, chest_scroll_up = nil, chest_scroll_down = nil,
      chest_btns = {}, chest_cancel_btn = nil,
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

  -- config.logistics.reactors/.export_chest ist die kanonische Quelle
  -- waehrend der Laufzeit (main.lua laedt die persistierte Datei dort schon
  -- vor dem ersten config_normalizer.normalize()-Durchlauf hinein). Faellt
  -- kein config vor, wird als naechstes die Config des uebergebenen
  -- redstone_router probiert (gleiches Muster wie vorher) -- die Datei
  -- selbst wird nur gelesen, wenn wirklich keine der beiden vorliegt
  -- (z.B. minimal aufgebaute Tests ohne fs-Umgebung).
  local cfg = self.config
  local lg = cfg and (cfg.logistics or cfg) or nil
  local rr_cfg = self.redstone_router and self.redstone_router.config
  local rr_lg = rr_cfg and (rr_cfg.logistics or rr_cfg) or nil
  local file_state = nil
  local source, export_chest
  if lg and lg.reactors then
    source, export_chest = lg.reactors, lg.export_chest
  elseif rr_lg and rr_lg.reactors then
    source, export_chest = rr_lg.reactors, rr_lg.export_chest
  else
    file_state = load_state(self.config_path)
    source, export_chest = file_state.reactors, file_state.export_chest
  end
  self._ui.export_chest = export_chest
  self._ui.logistics_enabled = (lg and lg.enabled) == true
  for _, entry in ipairs(source or {}) do
    self._ui.reactors[#self._ui.reactors + 1] = copy_reactor(entry)
  end

  -- All router presentation modes are replaced by the fixed SCADA renderer.
  router_scada.attach(self)
  return self
end

function M:_find_reactor(reactor_id)
  for _, r in ipairs(self._ui.reactors) do
    if r.reactor_id == reactor_id then return r end
  end
end

-- ---- fixed SCADA renderers ----------------------------------------------------
-- All _render_* methods are attached per-instance by router_scada.attach(self).
-- No legacy runtime renderer remains in this module.

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
  elseif u.mode == "chest_pick" then
    self:_render_chest_pick(target, w, h); footer_center = "EXPORT-KISTE WAEHLEN"
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
  if hit(u.export_chest_btn, x, y) then
    u.mode = "chest_pick"
    u.chest_scroll = 0
    return true
  end
  if hit(u.logistics_btn, x, y) then
    u.logistics_enabled = not u.logistics_enabled
    self.set_logistics_enabled(u.logistics_enabled)
    return true
  end
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
    u.export_chest = lg and lg.export_chest or nil
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
      u.editing = { reactor_id = btn.id, label = btn.label, path = {},
        request_below = 0.25, fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30 }
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
  if hit(u.cooldown_minus, x, y) then editing.resupply_cooldown_s = math.max(0, (editing.resupply_cooldown_s or 30) - STEP_COOLDOWN_S); return true end
  if hit(u.cooldown_plus, x, y) then editing.resupply_cooldown_s = (editing.resupply_cooldown_s or 30) + STEP_COOLDOWN_S; return true end

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

function M:_handle_chest_pick_touch(x, y)
  local u = self._ui
  if hit(u.chest_scroll_up, x, y) then u.chest_scroll = math.max(0, u.chest_scroll - 1); return true end
  if hit(u.chest_scroll_down, x, y) then u.chest_scroll = u.chest_scroll + 1; return true end
  if hit(u.chest_cancel_btn, x, y) then
    u.mode = "list"
    return true
  end
  for _, btn in ipairs(u.chest_btns or {}) do
    if hit(btn, x, y) then
      u.export_chest = btn.name
      u.dirty = true
      u.mode = "list"
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
  if u.mode == "chest_pick" then return self:_handle_chest_pick_touch(x, y) end
  if u.mode == "path" then return self:_handle_path_touch(x, y) end
  return self:_handle_list_touch(x, y)
end

-- ---- persistence + valve teach-in --------------------------------------------

-- Speichert 1) atomar in die persistierte Datei, 2) uebernimmt bei Erfolg
-- die Arbeitskopie in config.logistics.export_chest/.reactors und stoesst
-- logistics_router:refresh_peripherals() an, damit die Export-Kisten-
-- Bindung und die daraus abgeleitete redstone_tree sofort aktuell sind.
function M:_do_save()
  local u = self._ui
  u.save.state = "SAVING"

  local snapshot = { export_chest = u.export_chest, reactors = {} }
  for _, r in ipairs(u.reactors) do snapshot.reactors[#snapshot.reactors + 1] = copy_reactor(r) end

  local ok_valid, verr = validate_state(snapshot)
  if not ok_valid then
    u.save.state = "FAILED"
    u.save.error = tostring(verr or "unbekannter Validierungsfehler")
    u.save.saved_at = nil
    self.log("WARN", "RouterUI: Speichern abgelehnt (Validierung fehlgeschlagen): " .. tostring(u.save.error))
    return false
  end

  local ok, err_code, err_msg = save_state_atomic(snapshot, self.config_path, function(content)
    return validate_state(content)
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
    lg.export_chest = snapshot.export_chest
    lg.reactors = snapshot.reactors
    if self.logistics_router then self.logistics_router:refresh_peripherals() end
  end

  u.dirty = false
  u.save.state = "SAVED"
  u.save.error = nil
  u.save.saved_at = os.epoch and os.epoch("utc") or nil
  self.log("INFO", "RouterUI: saved " .. #snapshot.reactors .. " reactors to " .. tostring(self.config_path))
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
