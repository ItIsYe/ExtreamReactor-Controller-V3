local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")
local redstone_router_lib = require("nodes.fuel.redstone_router")

local DEFAULT_ROUTE_CONFIG_PATH = "/xreactor_config/fuel_routes.lua"
local BUILTIN_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local RECENT_HIGHLIGHT_MS = 5000

-- Editor baut direkt eine ganze Ventilkette: Reaktor waehlen -> Ventil fuer
-- Ventil antippen (optional mit einem bekannten VALVE-Node als Ziel) ->
-- FERTIG. Nutzt die flache Routenliste mit geordnetem 'path' pro Reaktor
-- (siehe redstone_router.lua) -- normalize_tree() liest alte verschachtelte
-- Baeume automatisch in dieses Format um.
--
-- u.mode: "tree" | "edit" (Tab-Ebene, wie bisher).
-- u.edit_view (nur relevant wenn u.mode=="edit"): "list" | "path".
--   "list": Reaktorliste mit ihrer jeweiligen Ventilkette als Zusammen-
--     fassung -- Antippen eines Reaktors wechselt zu "path".
--   "path": Editor fuer GENAU EINEN Reaktor (u.editing), Ventil fuer Ventil
--     antippen fuegt einen weiteren Schritt an, FERTIG committet die
--     Aenderung in u.routes, ABBRECHEN verwirft sie.

local function load_routes(path)
  path = path or DEFAULT_ROUTE_CONFIG_PATH
  if not fs.exists(path) then return {} end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then return result end
  return {}
end

-- Serialisiert die flache Routenliste (siehe redstone_router.lua's neues
-- Format): { { reactor=, label=, path = { {side=,integrator=}, ... } }, ... }
local function write_routes_file(routes, path)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local ok_open, f = pcall(fs.open, path, "w")
  if not ok_open or not f then return false end
  f.writeLine("-- Fuel router configuration -- auto-generated, do not edit manually")
  f.writeLine("return {")
  for _, r in ipairs(routes) do
    f.writeLine(string.format("  { reactor = %q, label = %q, path = {", r.reactor or "", r.label or r.reactor or ""))
    for _, step in ipairs(r.path or {}) do
      f.writeLine(string.format("    { side = %q%s },", step.side or "",
        step.integrator and (", integrator = " .. string.format("%q", step.integrator)) or ""))
    end
    f.writeLine("  } },")
  end
  f.writeLine("}")
  f.close()
  return true
end

-- Atomarer Schreibablauf (statt direkt auf den Zielpfad zu schreiben, wo ein
-- Schreibabbruch die letzte gueltige Routendatei zerstoeren koennte):
--   1. Inhalt nach <path>.tmp schreiben
--   2. .tmp erneut einlesen (bestaetigt: die Datei ist als Lua ladbar)
--   3. .tmp-Inhalt validieren (validate_fn, z.B. validate_tree())
--   4. bestehende Zieldatei (falls vorhanden) nach <path>.prev verschieben
--   5. .tmp nach <path> verschieben
--   6. finale Datei ERNEUT einlesen (bestaetigt: der Verschiebevorgang
--      selbst hat nichts beschaedigt)
--   7. finale Datei ERNEUT validieren
--   8. .prev ERST NACH vollstaendigem Erfolg entfernen
-- Bei jedem Fehlschlag wird die letzte bekannte gueltige Datei
-- wiederhergestellt (falls schon verschoben) bzw. gar nicht erst
-- angetastet (falls der Fehler vor Schritt 4 auftrat).
local function save_routes_atomic(routes, path, validate_fn)
  local tmp_path = path .. ".tmp"
  local prev_path = path .. ".prev"

  -- Schritt 1: nach .tmp schreiben
  if not write_routes_file(routes, tmp_path) then
    pcall(fs.delete, tmp_path)
    return false, "TMP_WRITE_FAILED", "Konnte " .. tmp_path .. " nicht schreiben"
  end

  -- Schritt 2+3: .tmp einlesen und validieren
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

  -- Schritt 4: bestehende Zieldatei sichern (falls vorhanden)
  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(prev_path) then pcall(fs.delete, prev_path) end
    local ok_bak = pcall(fs.move, path, prev_path)
    if not ok_bak then
      pcall(fs.delete, tmp_path)
      return false, "BACKUP_FAILED", "Konnte bestehende Datei nicht nach " .. prev_path .. " sichern"
    end
  end

  -- Schritt 5: .tmp an die Zielposition verschieben
  local ok_move = pcall(fs.move, tmp_path, path)
  if not ok_move then
    -- letzte gueltige Datei wiederherstellen, falls sie schon verschoben wurde
    if had_old and fs.exists(prev_path) and not fs.exists(path) then
      pcall(fs.move, prev_path, path)
    end
    pcall(fs.delete, tmp_path)
    return false, "MOVE_FAILED", "Konnte .tmp nicht nach " .. path .. " verschieben"
  end

  -- Schritt 6+7: finale Datei erneut einlesen und validieren
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

  -- Schritt 8: erst jetzt, nach vollstaendigem Erfolg, .prev entfernen
  if had_old and fs.exists(prev_path) then pcall(fs.delete, prev_path) end
  return true
end

local function deep_copy_path(path)
  local out = {}
  for i, step in ipairs(path or {}) do out[i] = { side = step.side, integrator = step.integrator } end
  return out
end

local function step_label(step)
  return tostring(step.side or "-") .. (step.integrator and (" @" .. tostring(step.integrator)) or "")
end

local function path_text(path)
  local parts = {}
  for _, step in ipairs(path or {}) do parts[#parts + 1] = step_label(step) end
  if #parts == 0 then return "KEIN VENTIL" end
  return table.concat(parts, " > ")
end

-- Bekannte, online erreichbare VALVE-Nodes (per HELLO/Heartbeat-Discovery,
-- siehe redstone_router.lua) -- Grundlage fuer den Integrator-Auswahl-
-- Schritt beim Anfuegen eines Ventils. Ohne comms-Anbindung oder ohne
-- bekannte VALVE-Nodes bleibt die Liste leer, ein Ventil wird dann direkt
-- als lokale Seite angefuegt (kein zusaetzlicher Auswahlschritt noetig).
-- Truncated to keep the picker row readable next to the raw id -- see
-- installer/valve_naming.lua for where this label comes from.
local VALVE_LABEL_MAX = 18

local function short_valve_label(id, label)
  label = (type(label) == "string" and label ~= "") and label or id
  return mux.fit(tostring(label), VALVE_LABEL_MAX)
end

-- Returns { { id=, label= }, ... }, sorted by id -- id is the stable key
-- stored in fuel_routes.lua (step.integrator); label is only for display.
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

function M.new(opts)
  opts = opts or {}
  local self = {
    redstone_router = opts.redstone_router,
    log = opts.log or function() end,
    get_reactors = opts.get_reactors or function() return {} end,
    get_active_route = opts.get_active_route,
    config_path = opts.config_path or DEFAULT_ROUTE_CONFIG_PATH,
    -- Ergebnis des Start-Ladevorgangs aus main.lua, nur zur Anzeige durchgereicht.
    routing_load_status = opts.routing_load_status,
    _ui = {
      mode = "tree",
      edit_view = "list",
      routes = {},
      dirty = false,
      reactor_btns = {}, save_btn = nil, reset_btn = nil,
      tree_btn = nil, edit_btn = nil, empty_edit_btn = nil,
      scroll = 0, scroll_up = nil, scroll_down = nil,
      list_scroll = 0, list_scroll_up = nil, list_scroll_down = nil,
      path_scroll = 0, path_scroll_up = nil, path_scroll_down = nil,
      picker_scroll = 0, picker_scroll_up = nil, picker_scroll_down = nil,
      -- Pfad-Editor-Zustand (nur waehrend edit_view=="path").
      editing = nil,          -- { reactor=, label=, path = {...} }, Arbeitskopie
      pending_side = nil,     -- Seite antippen -> Integrator waehlen -> anfuegen
      step_btns = {}, side_btns = {}, integrator_btns = {},
      done_btn = nil, cancel_btn = nil, clear_btn = nil,
      -- "Weg 3"-Teach-in (siehe handle_teach_pulse()); wird beim Verlassen
      -- des Pfad-Editors automatisch zurueckgesetzt, damit ein spaeter
      -- eintreffender Puls nicht versehentlich eine andere Bearbeitung
      -- beeinflusst.
      teaching = false, teach_btn = nil,
      -- Expliziter Save-Zustand statt nur eines "dirty"-Flags -- klare
      -- Unterscheidung GESPEICHERT/WIRD GESPEICHERT/FEHLGESCHLAGEN mit Fehlertext.
      save = { state = "IDLE", error = nil, saved_at = nil },
    },
  }
  -- config.logistics.redstone_tree ist die alleinige kanonische Quelle --
  -- normalize_tree() (dieselbe Funktion wie M:refresh()) liefert die
  -- Routenliste direkt aus der echten, aktiven Config, statt aus der
  -- separaten Datei fuel_routes.lua, die davon abweichen koennte.
  if self.redstone_router and self.redstone_router.config then
    local cfg = self.redstone_router.config
    local lg = cfg.logistics or cfg
    self._ui.routes = redstone_router_lib.normalize_tree(lg.redstone_tree or {})
  else
    self._ui.routes = redstone_router_lib.normalize_tree(load_routes(self.config_path))
  end
  return setmetatable(self, { __index = M })
end

function M:_find_route(reactor_id)
  for _, r in ipairs(self._ui.routes) do
    if r.reactor == reactor_id then return r end
  end
end

function M:_active_route()
  if type(self.get_active_route) == "function" then
    local ok, route = pcall(self.get_active_route)
    if ok and type(route) == "table" then return route end
  end
  if self.redstone_router and type(self.redstone_router.get_active_route) == "function" then
    local ok, route = pcall(self.redstone_router.get_active_route, self.redstone_router)
    if ok and type(route) == "table" then return route end
  end
  return {}
end

-- handle_touch() aendert nur lokalen Zustand und gibt true zurueck (Event
-- konsumiert) -- kein eigener render()-Aufruf mehr hier, das wuerde mit dem
-- zentralen ui_service-Renderpfad kollidieren. Ein konsumierter Touch loest
-- laut services/ui_service.lua ohnehin garantiert im selben Eventzyklus
-- einen zentralen Render-Durchlauf aus (Zeit-Drossel wird dafuer umgangen).

function M:_render_mode_tabs(target, ui, w)
  local u = self._ui
  local tx = math.max(2, w - 20)
  mux.badge(target, tx, 3, "TREE", u.mode == "tree" and "OK" or "OFFLINE")
  u.tree_btn = { x1 = tx, x2 = tx + 5, y = 3 }
  mux.badge(target, tx + 7, 3, "EDIT", u.mode == "edit" and "LIMITED" or "OFFLINE")
  u.edit_btn = { x1 = tx + 7, x2 = tx + 12, y = 3 }
end

function M:_render_tree(target, ui, w, h)
  local u = self._ui
  local routes = self.redstone_router and self.redstone_router.get_tree and self.redstone_router:get_tree() or u.routes
  local active = self:_active_route()
  local now = os.epoch and os.epoch("utc") or 0
  local active_path = active.path
  local active_target = active.target
  local recent = false
  if not active_target and active.last_target and active.last_active_ts and now > 0 then
    recent = (now - active.last_active_ts) <= RECENT_HIGHLIGHT_MS
    if recent then
      active_target = active.last_target
      active_path = active.last_path
    end
  end

  local valve_status_summary = self.redstone_router and self.redstone_router.get_valve_status and self.redstone_router:get_valve_status() or {}
  local offline_count = 0
  for _, vs in ipairs(valve_status_summary) do if vs.online == false then offline_count = offline_count + 1 end end
  local valve_label_text = string.format("VENTILE %d", self.redstone_router and self.redstone_router:valve_count() or 0)
  local valve_key = "OK"
  if offline_count > 0 then
    valve_label_text = valve_label_text .. string.format(" (%d OFFLINE)", offline_count)
    valve_key = "WARNING"
  elseif #routes == 0 then
    valve_key = "WARNING"
  end
  mux.status_dot(target, 2, 3, valve_label_text, valve_key, math.floor(w * 0.33))
  if w >= 40 then
    if self.routing_load_status and self.routing_load_status.ok == false then
      mux.status_dot(target, math.floor(w * 0.35), 3, "ROUTING INVALID: " .. mux.fit(tostring(self.routing_load_status.message or self.routing_load_status.code or "?"), 18), "WARNING", math.max(1, w - math.floor(w * 0.35) - 2))
    else
      mux.status_dot(target, math.floor(w * 0.35), 3, string.format("ROUTEN %d", #routes), #routes > 0 and "OK" or "LIMITED")
    end
  end

  local banner_text, banner_key
  if active.target then
    banner_text = "AKTIV -> " .. tostring(active.target) .. " VIA " .. table.concat(active.path or {}, " > ")
    banner_key = "OK"
  elseif recent and active_target then
    banner_text = "ZULETZT -> " .. tostring(active_target) .. " VIA " .. table.concat(active_path or {}, " > ")
    banner_key = "LIMITED"
  else
    banner_text = "KEIN AKTIVER ROUTING-PFAD"
    banner_key = "muted"
  end
  mux.banner(target, 2, 5, w - 3, banner_text, banner_key, "flow")

  local wide = w >= 72
  local left_w = wide and math.floor((w - 5) * 0.6) or (w - 3)
  local right_x = left_w + 3
  local right_w = w - right_x - 1
  local body_top = 7
  local body_bottom = h - 2
  local body_h = math.max(6, body_bottom - body_top + 1)

  -- Eine Route mit offline/stale Ventil im Pfad gilt nie als vollstaendig
  -- "OK", unabhaengig davon, ob sie gerade aktiv ist.
  local function route_has_bad_valve(route_label)
    for _, vs in ipairs(valve_status_summary) do
      for _, affected_label in ipairs(vs.affected_routes or {}) do
        if affected_label == route_label and (vs.online == false or vs.stale == true) then
          return true, vs.id
        end
      end
    end
    return false
  end

  mux.card(target, 2, body_top, left_w, body_h, { title = "REAKTOR-PFADE", status = #routes > 0 and "OK" or "WARNING", icon = "reactor" })
  local rows = routes
  local first_y = body_top + 1
  local visible = math.max(1, body_h - 3)
  local max_scroll = math.max(0, #rows - visible)
  u.scroll = math.max(0, math.min(u.scroll or 0, max_scroll))

  local y = first_y
  for i = u.scroll + 1, math.min(#rows, u.scroll + visible) do
    local route = rows[i]
    local is_target = active_target and (tostring(route.reactor or "") == tostring(active_target) or tostring(route.label or "") == tostring(active_target))
    local has_bad_valve, bad_valve_id = route_has_bad_valve(tostring(route.label or route.reactor))
    local status = has_bad_valve and "WARNING" or (is_target and (recent and "LIMITED" or "OK") or "muted")
    local value_text = path_text(route.path)
    if has_bad_valve then value_text = value_text .. " [" .. bad_valve_id .. " OFFLINE]" end
    if is_target then value_text = value_text .. (recent and " [LAST]" or " [ACTIVE]") end
    mux.data_row(target, 4, y, left_w - 4, { label = tostring(route.label or route.reactor), value = mux.fit(value_text, math.max(1, left_w - 4 - #tostring(route.label or route.reactor) - 2)), status = status, icon = "reactor" })
    y = y + 1
  end

  if #rows == 0 then
    mux.warning_box(target, 4, first_y, left_w - 4, { "Keine Reaktor-Routen konfiguriert", "EDIT oeffnen und Reaktor-Ziel waehlen" }, "WARNING")
    u.empty_edit_btn = nil
    local edit_y = first_y + 4
    if edit_y <= body_top + body_h - 2 then
      local targets = self.get_reactors()
      local hint = #targets > 0 and "ROUTEN JETZT BEARBEITEN" or "RT ONLINE / REAKTOR KONFIGURIEREN"
      mux.data_row(target, 4, edit_y, left_w - 4, { label = "[ EDIT ROUTEN ]", value = hint, status = "LIMITED", icon = "config" })
      u.empty_edit_btn = { x1 = 4, x2 = math.max(4, left_w - 1), y = edit_y }
    end
  else
    u.empty_edit_btn = nil
  end

  if max_scroll > 0 then
    local sy = body_top + body_h - 1
    local info = string.format("%d-%d/%d", u.scroll + 1, math.min(#rows, u.scroll + visible), #rows)
    mux.text(target, 4, sy, info, colorset.get("muted"), colorset.get("background"))
    mux.badge(target, math.max(4, left_w - 12), sy, "UP", u.scroll > 0 and "LIMITED" or "OFFLINE")
    mux.badge(target, math.max(10, left_w - 6), sy, "DN", u.scroll < max_scroll and "LIMITED" or "OFFLINE")
    u.scroll_up = u.scroll > 0 and { x1 = math.max(4, left_w - 12), x2 = math.max(4, left_w - 12) + 3, y = sy } or nil
    u.scroll_down = u.scroll < max_scroll and { x1 = math.max(10, left_w - 6), x2 = math.max(10, left_w - 6) + 3, y = sy } or nil
  else
    u.scroll_up, u.scroll_down = nil, nil
  end

  if wide then
    mux.card(target, right_x, body_top, right_w, body_h, { title = "VENTILE", status = offline_count > 0 and "WARNING" or "OK", icon = "output" })
    local ry = body_top + 2
    for _, vs in ipairs(valve_status_summary) do
      if ry > body_top + body_h - 2 then break end
      local shared_suffix = #(vs.affected_routes or {}) > 1 and (" (geteilt: " .. table.concat(vs.affected_routes, ", ") .. ")") or ""
      local status = vs.online == false and "WARNING" or (vs.stale and "LIMITED" or "OK")
      local row_label = short_valve_label(vs.id, vs.label)
      mux.data_row(target, right_x + 2, ry, right_w - 4, {
        label = row_label,
        value = mux.fit((vs.online == false and "OFFLINE" or "ONLINE") .. shared_suffix, right_w - 4 - #row_label - 2),
        status = status, icon = "output",
      })
      ry = ry + 1
    end
    if #valve_status_summary == 0 then
      mux.warning_box(target, right_x + 2, body_top + 2, right_w - 4, { "Keine Funk-Ventile (VALVE-Nodes)", "Lokale Redstone-Seiten ohne Integrator" }, "LIMITED")
    end
  end
end

function M:_render_list(target, ui, w, h)
  local u = self._ui
  local reactors = self.get_reactors()
  mux.status_dot(target, 2, 3, string.format("ROUTEN %d/%d", #u.routes, #reactors),
    #u.routes > 0 and "OK" or "LIMITED", math.max(8, math.floor(w * 0.33)))

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
    mux.status_dot(target, math.floor(w * 0.35), 3, save_label, save_key, math.max(1, w - math.floor(w * 0.35) - 2))
  end

  local body_top = 5
  local button_y = math.max(body_top + 3, h - 2)
  local body_bottom = math.max(body_top + 2, button_y - 1)
  local body_h = body_bottom - body_top + 1
  mux.card(target, 2, 5, w - 3, body_h, { title = "REAKTOR ZIELE -- ANTIPPEN ZUM BEARBEITEN", status = #reactors > 0 and "OK" or "WARNING", icon = "reactor" })

  local first_y = body_top + 2
  local control_y = body_top + body_h - 1
  local visible = math.max(1, control_y - first_y)
  local max_scroll
  u.list_scroll, max_scroll = clamp_scroll(u.list_scroll, #reactors, visible)

  local reactor_btns = {}
  local y = first_y
  for i = u.list_scroll + 1, math.min(#reactors, u.list_scroll + visible) do
    local rx = reactors[i]
    local route = self:_find_route(rx.id)
    local value = route and path_text(route.path) or "NICHT ZUGEWIESEN"
    mux.data_row(target, 4, y, w - 6, { label = tostring(rx.label or rx.id), value = mux.fit(value, math.max(1, w - 6 - #tostring(rx.label or rx.id) - 2)), status = route and "OK" or "text", icon = "reactor" })
    reactor_btns[#reactor_btns + 1] = { x1 = 4, x2 = w - 3, y = y, id = rx.id, label = rx.label or rx.id }
    y = y + 1
  end
  u.reactor_btns = reactor_btns

  if #reactors == 0 and first_y <= control_y then
    mux.warning_box(target, 4, first_y, w - 6,
      { "Keine Reaktor-Ziele gefunden", "RT-Nodes online oder logistics.reactors konfigurieren" }, "WARNING")
  end

  if max_scroll > 0 then
    mux.text(target, 4, control_y,
      string.format("%d-%d/%d", u.list_scroll + 1, math.min(#reactors, u.list_scroll + visible), #reactors),
      colorset.get("muted"), colorset.get("background"))
    u.list_scroll_up, u.list_scroll_down = paging_badges(target, w - 2, control_y, u.list_scroll, max_scroll)
  else
    u.list_scroll_up, u.list_scroll_down = nil, nil
  end

  local save_lbl = u.dirty and "[ SPEICHERN * ]" or "[ SPEICHERN ]"
  local reset_lbl = "[ RESET ]"
  if w < 34 then save_lbl, reset_lbl = u.dirty and "[SAVE*]" or "[SAVE]", "[RST]" end
  mux.data_row(target, 2, button_y, w - 3, { label = save_lbl, value = reset_lbl, status = u.dirty and "LIMITED" or "OK", icon = "config" })
  u.save_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #save_lbl + 2), y = button_y }
  u.reset_btn = { x1 = math.max(2, w - #reset_lbl - 2), x2 = w - 1, y = button_y }
end

-- Editor fuer GENAU EINEN Reaktor (u.editing): zeigt die bisher
-- angefuegten Ventilschritte (antippen = entfernen), darunter die 6
-- Redstone-Seiten (antippen = anfuegen -- ist mindestens ein VALVE-Node
-- bekannt, fragt ein Zwischenschritt zuerst, ob lokal oder ueber einen
-- bestimmten VALVE-Node geschaltet werden soll). FERTIG committet die
-- Arbeitskopie in u.routes, ABBRECHEN verwirft sie.
function M:_render_path(target, ui, w, h)
  local u = self._ui
  local editing = u.editing
  if not editing then u.edit_view = "list"; return self:_render_list(target, ui, w, h) end

  mux.banner(target, 2, 3, w - 3, "VENTILKETTE: " .. tostring(editing.label or editing.reactor), "LIMITED", "reactor")

  local teach_lbl = u.teaching and "[ EINLERNEN: AN ]" or "[ EINLERNEN: AUS ]"
  local teach_hint = u.teaching and "Hebel am Ventil umlegen, um es anzuhaengen" or "Antippen zum Aktivieren"
  if w < 40 then
    teach_lbl = u.teaching and "[TEACH ON]" or "[TEACH]"
    teach_hint = u.teaching and "HEBEL" or "ANTIPPEN"
  end
  mux.data_row(target, 2, 4, w - 3, { label = teach_lbl, value = teach_hint, status = u.teaching and "OK" or "muted", icon = "network" })
  u.teach_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #teach_lbl + 1), y = 4 }

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
    local step = editing.path[i]
    mux.data_row(target, 4, sy, w - 6, { label = tostring(i) .. ".", value = step_label(step), status = "OK", icon = "output" })
    step_btns[#step_btns + 1] = { x1 = 4, x2 = w - 3, y = sy, index = i }
    sy = sy + 1
  end
  if #editing.path == 0 and sy <= content_top + chain_h - 1 then
    mux.text(target, 4, sy, mux.fit("(noch kein Ventil)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end
  u.step_btns = step_btns

  local side_btns, integrator_btns = {}, {}
  local items = {}
  if u.pending_side then
    mux.banner(target, 2, picker_top, w - 3, "SEITE " .. tostring(u.pending_side):upper() .. " -- ZIEL", "LIMITED", "network")
    items[#items + 1] = { label = "LOKAL", value = "FUEL-NODE", integrator = nil }
    for _, valve in ipairs(known_valve_ids(self.redstone_router)) do
      items[#items + 1] = { label = valve.label, value = "VALVE-NODE", integrator = valve.id }
    end
  else
    mux.card(target, 2, picker_top, w - 3, picker_h, { title = "VENTIL ANFUEGEN", status = "LIMITED", icon = "output" })
    for _, side in ipairs(BUILTIN_SIDES) do items[#items + 1] = { label = tostring(side):upper(), value = "ANTIPPEN", side = side } end
  end

  local visible_picker = math.max(1, picker_h - 1)
  local picker_max_scroll
  u.picker_scroll, picker_max_scroll = clamp_scroll(u.picker_scroll, #items, visible_picker)
  u.picker_scroll_up, u.picker_scroll_down = paging_badges(target, w - 2, picker_top, u.picker_scroll, picker_max_scroll)
  local picker_y = picker_top + 1
  for i = u.picker_scroll + 1, math.min(#items, u.picker_scroll + visible_picker) do
    local item = items[i]
    mux.data_row(target, 4, picker_y, w - 6, { label = item.label, value = item.value, status = "OK", icon = item.integrator and "network" or "output" })
    if u.pending_side then
      integrator_btns[#integrator_btns + 1] = { x1 = 4, x2 = w - 3, y = picker_y, integrator = item.integrator }
    else
      side_btns[#side_btns + 1] = { x1 = 4, x2 = w - 3, y = picker_y, side = item.side }
    end
    picker_y = picker_y + 1
  end
  u.side_btns = side_btns
  u.integrator_btns = integrator_btns

  local done_lbl, clear_lbl, cancel_lbl = "[ FERTIG ]", "[ LEEREN ]", "[ ABBRECHEN ]"
  if w < 40 then done_lbl, clear_lbl, cancel_lbl = "[OK]", "[CLR]", "[X]" end
  mux.data_row(target, 2, button_y, w - 3, { label = done_lbl, value = clear_lbl .. " " .. cancel_lbl, status = "OK", icon = "config" })
  u.done_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #done_lbl + 1), y = button_y }
  u.cancel_btn = { x1 = math.max(2, w - #cancel_lbl - 1), x2 = w - 1, y = button_y }
  u.clear_btn = { x1 = math.max(2, u.cancel_btn.x1 - #clear_lbl - 2), x2 = math.max(2, u.cancel_btn.x1 - 2), y = button_y }
end

-- Nur der zentrale Render-Pfad (core/ui_router.lua) uebergibt den echten
-- should_clear-Wert und kann das Clearing gezielt unterdruecken.
function M:render(target, ui, colors, should_clear)
  -- Fix: Default false -- ui_router setzt should_clear korrekt;
  -- true nur bei Transition. Default true verursacht Flackern.
  if should_clear == nil then should_clear = false end
  local w, h = ui.getSize(target)
  -- Fix: ui.getSize schlägt bei Window-Targets manchmal fehl (safe_monitor_call)
  -- Direkt-Fallback über pcall damit render nicht abbricht und edit_btn nil bleibt
  if not w or not h then
    local ok, fw, fh = pcall(function() return target.getSize() end)
    if ok and fw and fh then w, h = fw, fh else return end
  end
  local u = self._ui
  local page_status = u.save.state == "FAILED" and "WARNING" or (u.mode == "edit" and u.dirty and "LIMITED" or "OK")
  if should_clear then mux.clear(target) end
  mux.header(target, { title = "REDSTONE ROUTING", node_id = "FUEL NODE", page = "4/4", status = page_status, icon = "network" })
  local footer_center
  if u.mode == "edit" then
    if u.edit_view == "path" then
      self:_render_path(target, ui, w, h)
      footer_center = "VENTILKETTE"
    else
      self:_render_list(target, ui, w, h)
      footer_center = "ROUTER EDIT"
    end
  else
    self:_render_tree(target, ui, w, h)
    footer_center = "ROUTING TREE"
  end
  -- TREE/EDIT must be the final writer on row 3. Tree/list status rows also
  -- use row 3 and previously covered the visible EDIT control.
  self:_render_mode_tabs(target, ui, w)
  return mux.footer_nav(target, h, w, { center = footer_center, inset = 3 })
end

function M:handle_touch(x, y)
  local u = self._ui
  local function hit(b) return b and y == b.y and x >= b.x1 and x <= b.x2 end

  if hit(u.list_scroll_up) then u.list_scroll = math.max(0, u.list_scroll - 1); return true end
  if hit(u.list_scroll_down) then u.list_scroll = u.list_scroll + 1; return true end
  if hit(u.path_scroll_up) then u.path_scroll = math.max(0, u.path_scroll - 1); return true end
  if hit(u.path_scroll_down) then u.path_scroll = u.path_scroll + 1; return true end
  if hit(u.picker_scroll_up) then u.picker_scroll = math.max(0, u.picker_scroll - 1); return true end
  if hit(u.picker_scroll_down) then u.picker_scroll = u.picker_scroll + 1; return true end

  if hit(u.tree_btn) then
    u.mode = "tree"
    return true
  end
  if hit(u.edit_btn) or hit(u.empty_edit_btn) then
    u.mode = "edit"
    u.edit_view = "list"
    u.editing = nil
    u.pending_side = nil
    u.list_scroll = 0
    return true
  end

  if u.mode == "tree" then
    if hit(u.scroll_up) then
      u.scroll = math.max(0, (u.scroll or 0) - 1)
      return true
    end
    if hit(u.scroll_down) then
      u.scroll = (u.scroll or 0) + 1
      return true
    end
    return false
  end

  if u.edit_view == "path" then
    if hit(u.teach_btn) then
      u.teaching = not u.teaching
      return true
    end
    if hit(u.cancel_btn) then
      u.editing = nil
      u.pending_side = nil
      u.teaching = false
      u.edit_view = "list"
      u.picker_scroll = 0
      return true
    end
    if hit(u.done_btn) then
      if u.editing then
        local new_routes = {}
        for _, r in ipairs(u.routes) do
          if r.reactor ~= u.editing.reactor then new_routes[#new_routes + 1] = r end
        end
        new_routes[#new_routes + 1] = { reactor = u.editing.reactor, label = u.editing.label, path = deep_copy_path(u.editing.path) }
        u.routes = new_routes
        u.dirty = true
      end
      u.editing = nil
      u.pending_side = nil
      u.teaching = false
      u.edit_view = "list"
      u.picker_scroll = 0
      return true
    end
    if hit(u.clear_btn) then
      if u.editing then u.editing.path = {} end
      u.pending_side = nil
      u.path_scroll = 0
      u.picker_scroll = 0
      return true
    end
    for _, btn in ipairs(u.step_btns or {}) do
      if hit(btn) then
        if u.editing then table.remove(u.editing.path, btn.index) end
        return true
      end
    end
    if u.pending_side then
      for _, btn in ipairs(u.integrator_btns or {}) do
        if hit(btn) then
          if u.editing then
            u.editing.path[#u.editing.path + 1] = { side = u.pending_side, integrator = btn.integrator }
          end
          u.pending_side = nil
          u.picker_scroll = 0
          return true
        end
      end
      return false
    end
    for _, btn in ipairs(u.side_btns or {}) do
      if hit(btn) then
        local known = known_valve_ids(self.redstone_router)
        if #known > 0 then
          u.pending_side = btn.side
          u.picker_scroll = 0
        elseif u.editing then
          u.editing.path[#u.editing.path + 1] = { side = btn.side }
        end
        return true
      end
    end
    return false
  end

  -- u.edit_view == "list"
  if hit(u.save_btn) then
    self:_do_save()
    return true
  end
  if hit(u.reset_btn) then
    u.routes = {}
    u.dirty = true
    return true
  end
  for _, btn in ipairs(u.reactor_btns or {}) do
    if hit(btn) then
      local existing = self:_find_route(btn.id)
      u.editing = existing
        and { reactor = existing.reactor, label = existing.label, path = deep_copy_path(existing.path) }
        or { reactor = btn.id, label = btn.label, path = {} }
      u.pending_side = nil
      u.edit_view = "path"
      u.path_scroll = 0
      u.picker_scroll = 0
      return true
    end
  end
  return false
end

-- Save-Ablauf: 1) redstone_tree direkt aus den Editor-Routes bauen, 2) mit
-- derselben validate_tree()-Funktion pruefen wie der Router selbst, 3) nur
-- bei gueltigem Ergebnis committen + Router aktualisieren, 4) expliziten
-- Save-Zustand setzen (SAVED/FAILED mit genauem Fehler).
function M:_do_save()
  local u = self._ui
  u.save.state = "SAVING"

  local new_tree = {}
  for _, r in ipairs(u.routes) do
    new_tree[#new_tree + 1] = { reactor = r.reactor, label = r.label, path = deep_copy_path(r.path) }
  end

  local validation = redstone_router_lib.validate_tree(new_tree)
  if not validation.ok then
    local first_err = validation.errors[1]
    u.save.state = "FAILED"
    u.save.error = first_err and ("[" .. first_err.code .. "] " .. first_err.message) or "unbekannter Validierungsfehler"
    u.save.saved_at = nil
    self.log("WARN", "RouterUI: Speichern abgelehnt (Validierung fehlgeschlagen): " .. tostring(u.save.error))
    return false
  end

  local ok, err_code, err_msg = save_routes_atomic(u.routes, self.config_path, function(content)
    if type(content) ~= "table" then return false, "gespeicherter Inhalt ist keine Tabelle" end
    local v = redstone_router_lib.validate_tree(content)
    if not v.ok then
      local fe = v.errors[1]
      return false, fe and ("[" .. fe.code .. "] " .. fe.message) or "Validierung fehlgeschlagen"
    end
    return true
  end)
  if not ok then
    u.save.state = "FAILED"
    u.save.error = tostring(err_code) .. ": " .. tostring(err_msg)
    self.log("WARN", "RouterUI: atomarer Schreibvorgang fehlgeschlagen (" .. tostring(self.config_path) .. "): " .. tostring(err_code) .. " - " .. tostring(err_msg))
    return false
  end

  if self.redstone_router then
    local cfg = self.redstone_router.config
    local lg = cfg.logistics or cfg
    lg.redstone_tree = new_tree
    self.redstone_router:refresh()
    -- Operativen Zustand zurueckLesen statt blind anzunehmen, dass er dem
    -- gerade Geschriebenen entspricht.
    local validation_state = self.redstone_router.get_validation and self.redstone_router:get_validation() or { ok = true }
    if not validation_state.ok then
      u.save.state = "FAILED"
      local first_err = validation_state.errors and validation_state.errors[1]
      u.save.error = first_err and ("Router lehnt gespeicherten Baum ab: [" .. first_err.code .. "] " .. first_err.message) or "Router lehnt gespeicherten Baum ab"
      self.log("WARN", "RouterUI: " .. tostring(u.save.error))
      return false
    end
    self.log("INFO", "RouterUI: redstone_router updated with " .. #u.routes .. " routes")
  end

  u.dirty = false
  u.save.state = "SAVED"
  u.save.error = nil
  u.save.saved_at = os.epoch and os.epoch("utc") or nil
  self.log("INFO", "RouterUI: saved " .. #u.routes .. " routes to " .. tostring(self.config_path))
  return true
end

function M:get_routes()
  return self._ui.routes
end

-- "Weg 3"-Teach-in: der Spieler laeuft die physische Rohrleitung ab und legt
-- an jedem Ventil kurz einen Hebel um (siehe nodes/valve/main.lua's
-- check_teach_input()/ROUTE_TEACH_PULSE); die gemeldete Node wird in genau
-- dieser Reihenfolge an die Kette angehaengt, waehrend der Teach-Modus aktiv
-- ist. "side" ist fuer eine per Funk adressierte VALVE-Node physisch
-- bedeutungslos (nur ein von normalize_tree()/validate_tree() verlangter
-- Schluessel-Bestandteil) -- ein fester Platzhalter genuegt.
local TEACH_PLACEHOLDER_SIDE = "back"

function M:handle_teach_pulse(node_id)
  local u = self._ui
  if not node_id then return false end
  if u.mode ~= "edit" or u.edit_view ~= "path" or not u.editing or not u.teaching then return false end
  local last = u.editing.path[#u.editing.path]
  if last and last.integrator == node_id then return false end  -- Doppel-Puls/Prellen ignorieren
  u.editing.path[#u.editing.path + 1] = { side = TEACH_PLACEHOLDER_SIDE, integrator = node_id }
  return true
end

return M
