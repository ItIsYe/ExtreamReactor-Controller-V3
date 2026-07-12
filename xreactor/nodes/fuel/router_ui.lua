local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local DEFAULT_ROUTE_CONFIG_PATH = "/xreactor/config/fuel_routes.lua"
local BUILTIN_SIDES = { "top", "bottom", "left", "right", "front", "back" }
local RECENT_HIGHLIGHT_MS = 5000

local function load_routes(path)
  path = path or DEFAULT_ROUTE_CONFIG_PATH
  if not fs.exists(path) then return {} end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" then return result end
  return {}
end

local function save_routes(routes, path)
  path = path or DEFAULT_ROUTE_CONFIG_PATH
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.writeLine("-- Fuel router configuration -- auto-generated, do not edit manually")
  f.writeLine("return {")
  for _, r in ipairs(routes) do
    f.writeLine(string.format(
      "  { side = %q, reactor = %q, label = %q%s },",
      r.side or "", r.reactor or "", r.label or r.reactor or "",
      r.integrator and (", integrator = " .. string.format("%q", r.integrator)) or ""
    ))
  end
  f.writeLine("}")
  f.close()
  return true
end

local function copy_path(path)
  local out = {}
  for i, v in ipairs(path or {}) do out[i] = v end
  return out
end

local function path_is_prefix(prefix, full)
  if not prefix or not full or #prefix > #full then return false end
  for i = 1, #prefix do
    if tostring(prefix[i]) ~= tostring(full[i]) then return false end
  end
  return true
end

local function flatten_tree(nodes, out, ancestors_last, path)
  out = out or {}
  ancestors_last = ancestors_last or {}
  path = path or {}
  local count = #(nodes or {})
  for i, node in ipairs(nodes or {}) do
    local is_last = i == count
    local node_path = copy_path(path)
    if node.side then node_path[#node_path + 1] = tostring(node.side) end
    out[#out + 1] = {
      node = node,
      is_last = is_last,
      ancestors_last = copy_path(ancestors_last),
      path = node_path,
      depth = #ancestors_last,
    }
    local next_anc = copy_path(ancestors_last)
    next_anc[#next_anc + 1] = is_last
    flatten_tree(node.children or {}, out, next_anc, node_path)
  end
  return out
end

local function tree_prefix(row)
  local parts = {}
  for _, parent_last in ipairs(row.ancestors_last or {}) do
    parts[#parts + 1] = parent_last and "   " or "│  "
  end
  parts[#parts + 1] = row.is_last and "└─ " or "├─ "
  return table.concat(parts)
end

local function valve_label(node)
  local side = tostring(node.side or "-")
  local integrator = node.integrator and (" @" .. tostring(node.integrator)) or ""
  return "[" .. side .. integrator .. "]"
end

function M.new(opts)
  opts = opts or {}
  local self = {
    redstone_router = opts.redstone_router,
    log = opts.log or function() end,
    get_reactors = opts.get_reactors or function() return {} end,
    get_active_route = opts.get_active_route,
    config_path = opts.config_path or DEFAULT_ROUTE_CONFIG_PATH,
    _ui = {
      mode = "tree",
      selected_side = nil,
      selected_int = nil,
      routes = {},
      dirty = false,
      side_btns = {}, reactor_btns = {}, save_btn = nil, reset_btn = nil,
      tree_btn = nil, edit_btn = nil,
      scroll = 0, scroll_up = nil, scroll_down = nil,
      -- Feature (2026-07-11): UI-P0.8 (siehe docs/CODING_AI_FUEL_UI_
      -- PRIORITY_FIX_2026-07-12.md). Expliziter Save-Zustand statt nur
      -- eines einzelnen "dirty"-Flags -- die Seite kann dadurch klar
      -- zwischen GESPEICHERT/WIRD GESPEICHERT/FEHLGESCHLAGEN unterscheiden
      -- und den exakten Fehler anzeigen statt nur "hat nicht geklappt".
      save = { state = "IDLE", error = nil, saved_at = nil },
    },
  }
  -- Fix (2026-07-11): CRITICAL, UI-P0.8. Vorher wurde beim Start aus der
  -- SEPARATEN Datei fuel_routes.lua geladen (load_routes()) -- komplett
  -- unabhaengig von config.logistics.redstone_tree, dem tatsaechlich
  -- operativ genutzten Zustand (siehe redstone_router.lua). Die Seite
  -- konnte dadurch etwas ANDERES anzeigen als das, was der Router
  -- tatsaechlich verwendet. Jetzt: redstone_tree ist die alleinige
  -- kanonische Quelle -- die (bereits vorhandene, fuer die Baumansicht
  -- genutzte) flatten_tree()-Funktion liefert die flache Editor-Ansicht
  -- direkt aus dem echten operativen Baum, keine separate Datei mehr.
  if self.redstone_router and self.redstone_router.config then
    local cfg = self.redstone_router.config
    local lg = cfg.logistics or cfg
    local tree = lg.redstone_tree or {}
    local flat = flatten_tree(tree)
    for _, row in ipairs(flat) do
      if row.node.reactor then
        self._ui.routes[#self._ui.routes + 1] = {
          side = row.node.side, integrator = row.node.integrator,
          reactor = row.node.reactor, label = row.node.label or row.node.reactor,
        }
      end
    end
    -- Fix (2026-07-11): falls der geladene Baum verschachtelt ist (echte
    -- Kind-Knoten unterhalb eines Ventils, nicht nur ein flacher Endpunkt),
    -- kann dieser rein flache Editor das NICHT abbilden -- ein Speichern
    -- wuerde diese Struktur zerstoeren. Deutlich sichtbare Warnung statt
    -- stillschweigendem Datenverlust beim naechsten Speichern.
    local function has_nested_children(nodes)
      for _, node in ipairs(nodes or {}) do
        if type(node.children) == "table" and #node.children > 0 then return true end
        if has_nested_children(node.children) then return true end
      end
      return false
    end
    self._ui.tree_has_nesting = has_nested_children(tree)
  else
    self._ui.routes = load_routes(self.config_path)
  end
  return setmetatable(self, { __index = M })
end

function M:_find(side, integrator)
  for _, r in ipairs(self._ui.routes) do
    if r.side == side and (r.integrator or nil) == (integrator or nil) then return r end
  end
end

function M:_remove(side, integrator)
  local new = {}
  for _, r in ipairs(self._ui.routes) do
    if not (r.side == side and (r.integrator or nil) == (integrator or nil)) then new[#new + 1] = r end
  end
  self._ui.routes = new
  self._ui.dirty = true
end

function M:_assign(side, integrator, reactor_id, label)
  self:_remove(side, integrator)
  self._ui.routes[#self._ui.routes + 1] = {
    side = side, integrator = integrator or nil, reactor = reactor_id, label = label,
  }
  self._ui.dirty = true
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

-- Fix (2026-07-11): UI-P0.7 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_FIX_
-- 2026-07-12.md). M:_redraw() rief render() bisher DIREKT und
-- SELBSTSTAENDIG auf, ausserhalb des zentralen ui_service -> monitor_ui
-- -> ui_router-Renderpfads -- das konnte mit einem regulaeren, zentral
-- ausgeloesten Render-Durchlauf kollidieren (zwei unabhaengige
-- Zeichenversuche fuer denselben Frame) und Snapshot-/Zustandsvergleiche
-- auseinanderlaufen lassen. Jetzt entfernt: handle_touch() aendert nur
-- noch den lokalen Zustand (u.mode, u.selected_side, ...) und gibt true
-- zurueck (Event konsumiert) -- da ein konsumierter Touch bereits laut
-- UI-P0.5 (services/ui_service.lua) als "interaktiv" GARANTIERT im
-- selben Eventzyklus einen zentralen Render-Durchlauf ausloest (die
-- Zeit-Drossel wird fuer interaktive Events umgangen), bleibt die
-- Aenderung trotzdem sofort sichtbar -- nur eben ueber den einen,
-- zentralen Pfad statt einem zweiten, parallelen.

function M:_render_mode_tabs(target, ui, w)
  local u = self._ui
  local tx = math.max(2, w - 20)
  ui.badge(target, tx, 3, "TREE", u.mode == "tree" and "OK" or "OFFLINE")
  u.tree_btn = { x1 = tx, x2 = tx + 5, y = 3 }
  ui.badge(target, tx + 7, 3, "EDIT", u.mode == "edit" and "LIMITED" or "OFFLINE")
  u.edit_btn = { x1 = tx + 7, x2 = tx + 12, y = 3 }
end

function M:_render_tree(target, ui, w, h)
  local u = self._ui
  local tree = self.redstone_router and self.redstone_router.get_tree and self.redstone_router:get_tree() or {}
  local routes = self.redstone_router and self.redstone_router.get_routing_table and self.redstone_router:get_routing_table() or {}
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

  mux.status_dot(target, 2, 3, string.format("VENTILE %d", self.redstone_router and self.redstone_router:valve_count() or 0), #tree > 0 and "OK" or "WARNING")
  if w >= 40 then mux.status_dot(target, math.floor(w * 0.35), 3, string.format("PFADE %d", #routes), #routes > 0 and "OK" or "LIMITED") end

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
  local tree_w = wide and math.floor((w - 5) * 0.64) or (w - 3)
  local route_x = tree_w + 3
  local route_w = w - route_x - 1
  local body_top = 7
  local body_bottom = h - 2
  local body_h = math.max(6, body_bottom - body_top + 1)

  mux.card(target, 2, body_top, tree_w, body_h, { title = "PHYSISCHER REDSTONE-BAUM", status = #tree > 0 and "OK" or "WARNING", icon = "network" })
  local rows = flatten_tree(tree)
  local first_y = body_top + 2
  local visible = math.max(1, body_h - 4)
  local max_scroll = math.max(0, #rows - visible)
  u.scroll = math.max(0, math.min(u.scroll or 0, max_scroll))

  ui.text(target, 4, body_top + 1, "ROOT / HAUPT-PIPE", colorset.get("OK"), colorset.get("background"))
  local y = first_y
  for i = u.scroll + 1, math.min(#rows, u.scroll + visible) do
    local row = rows[i]
    local node = row.node
    local on_path = active_path and path_is_prefix(row.path, active_path)
    local is_target = active_target and (tostring(node.reactor or "") == tostring(active_target) or tostring(node.label or "") == tostring(active_target))
    local status = is_target and "OK" or on_path and (recent and "LIMITED" or "OK") or "muted"
    local prefix = tree_prefix(row)
    local label = valve_label(node) .. " " .. tostring(node.label or node.reactor or "Ast")
    if node.reactor then label = label .. " -> " .. tostring(node.reactor) end
    if is_target then label = label .. (recent and " [LAST]" or " [ACTIVE]") end
    ui.text(target, 4, y, mux.fit(prefix .. label, tree_w - 4), colorset.get(status), colorset.get("background"))
    y = y + 1
  end

  if #rows == 0 then
    mux.warning_box(target, 4, first_y, tree_w - 4, { "Kein redstone_tree konfiguriert", "config.logistics.redstone_tree pruefen" }, "WARNING")
  end

  if max_scroll > 0 then
    local sy = body_top + body_h - 2
    local info = string.format("%d-%d/%d", u.scroll + 1, math.min(#rows, u.scroll + visible), #rows)
    ui.text(target, 4, sy, info, colorset.get("muted"), colorset.get("background"))
    ui.badge(target, math.max(4, tree_w - 12), sy, "UP", u.scroll > 0 and "LIMITED" or "OFFLINE")
    ui.badge(target, math.max(10, tree_w - 6), sy, "DN", u.scroll < max_scroll and "LIMITED" or "OFFLINE")
    u.scroll_up = u.scroll > 0 and { x1 = math.max(4, tree_w - 12), x2 = math.max(4, tree_w - 12) + 3, y = sy } or nil
    u.scroll_down = u.scroll < max_scroll and { x1 = math.max(10, tree_w - 6), x2 = math.max(10, tree_w - 6) + 3, y = sy } or nil
  else
    u.scroll_up, u.scroll_down = nil, nil
  end

  if wide then
    mux.card(target, route_x, body_top, route_w, body_h, { title = "REAKTOR-PFADE", status = #routes > 0 and "OK" or "WARNING", icon = "reactor" })
    local ry = body_top + 2
    for _, route in ipairs(routes) do
      if ry > body_top + body_h - 2 then break end
      local is_active = active_target and (tostring(route.reactor) == tostring(active_target) or tostring(route.label) == tostring(active_target))
      local status = is_active and (recent and "LIMITED" or "OK") or "muted"
      mux.data_row(target, route_x + 2, ry, route_w - 4, {
        label = tostring(route.label or route.reactor),
        value = table.concat(route.path or {}, ">"),
        status = status,
        icon = "reactor"
      })
      ry = ry + 1
    end
    if #routes == 0 then
      mux.warning_box(target, route_x + 2, body_top + 2, route_w - 4, { "Keine Reaktor-Pfade", "Baum-Endpunkte brauchen reactor=..." }, "WARNING")
    end
  end
end

function M:_render_edit(target, ui, w, h)
  local u = self._ui
  local reactors = self.get_reactors()
  local nest_suffix = u.tree_has_nesting and " [VERSCHACHTELT!]" or ""
  mux.status_dot(target, 2, 3, string.format("ROUTEN %d", #u.routes) .. nest_suffix, #u.routes > 0 and "OK" or "LIMITED", math.floor(w * 0.33))
  -- Fix (2026-07-11): UI-P0.8. Vorher nur ein simples SAVED/UNSAVED.
  -- Jetzt unterscheidet dieselbe Zeile klar zwischen GESPEICHERT=AKTIV,
  -- WIRD GESPEICHERT, FEHLGESCHLAGEN (mit Kurzfehler) und UNGESPEICHERTE
  -- AENDERUNGEN -- ohne eine zusaetzliche Zeile zu belegen (Kollision mit
  -- den mode-tabs/anderen Status-Punkten in dieser Reihe vermeiden).
  if w >= 40 then
    local save_label, save_key
    if u.save.state == "FAILED" then
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

  local gap = 2
  local left_w = math.floor((w - 4 - gap) / 2)
  local right_x = 2 + left_w + gap
  local right_w = w - right_x - 1
  local body_h = math.max(8, h - 10)
  mux.card(target, 2, 5, left_w, body_h, { title = "REDSTONE AUSGAENGE", status = "LIMITED", icon = "output" })
  mux.card(target, right_x, 5, right_w, body_h, { title = "REAKTOR ZIELE", status = #reactors > 0 and "OK" or "WARNING", icon = "reactor" })

  local side_btns, sy = {}, 7
  for _, side in ipairs(BUILTIN_SIDES) do
    if sy > 5 + body_h - 2 then break end
    local assigned = self:_find(side, nil)
    local selected = u.selected_side == side and u.selected_int == nil
    local key = selected and "LIMITED" or assigned and "OK" or "muted"
    local value = assigned and tostring(assigned.label or assigned.reactor or "?") or "FREI"
    mux.data_row(target, 4, sy, left_w - 4, { label = tostring(side):upper(), value = value, status = key, icon = selected and "config" or "output" })
    side_btns[#side_btns + 1] = { x1 = 4, x2 = left_w, y = sy, side = side, integrator = nil }
    sy = sy + 1
  end
  u.side_btns = side_btns

  local reactor_btns, ry = {}, 7
  for _, rx in ipairs(reactors) do
    if ry > 5 + body_h - 2 then break end
    local assigned = false
    for _, route in ipairs(u.routes) do if route.reactor == rx.id then assigned = true; break end end
    mux.data_row(target, right_x + 2, ry, right_w - 4, { label = tostring(rx.label or rx.id), value = assigned and "ASSIGNED" or "READY", status = assigned and "OK" or "text", icon = "reactor" })
    reactor_btns[#reactor_btns + 1] = { x1 = right_x + 2, x2 = right_x + right_w - 3, y = ry, id = rx.id, label = rx.label or rx.id }
    ry = ry + 1
  end
  u.reactor_btns = reactor_btns

  if #reactors == 0 then mux.warning_box(target, right_x + 2, 7, right_w - 4, { "Keine Ziele gefunden", "Discovery pruefen" }, "WARNING") end
  if h >= 18 then
    local hint = u.selected_side and ("AUSGANG " .. tostring(u.selected_side):upper() .. " GEWAEHLT -> ZIEL ANTIPPEN") or "AUSGANG ANTIPPEN -> DANACH ZIEL ANTIPPEN"
    mux.banner(target, 2, h - 4, w - 3, hint, u.selected_side and "LIMITED" or "muted", "network")
  end

  local btn_y = h - 2
  local save_lbl = u.dirty and "[ SPEICHERN * ]" or "[ SPEICHERN ]"
  local reset_lbl = "[ RESET ]"
  mux.data_row(target, 2, btn_y, w - 3, { label = save_lbl, value = reset_lbl, status = u.dirty and "LIMITED" or "OK", icon = "config" })
  u.save_btn = { x1 = 2, x2 = 2 + #save_lbl + 3, y = btn_y }
  u.reset_btn = { x1 = math.max(2, w - #reset_lbl - 2), x2 = w - 1, y = btn_y }
end

-- Fix (2026-07-11): UI-P0.6 (siehe docs/CODING_AI_FUEL_UI_PRIORITY_FIX_
-- 2026-07-12.md). should_clear ist optional und defaultet auf TRUE --
-- der direkte M:_redraw()-Aufrufpfad (nach einem lokalen Touch, siehe
-- Kommentar dort) ruft render() bisher mit nur 3 Argumenten auf und
-- bekommt dadurch weiterhin unveraendert bei JEDEM Touch ein volles
-- Clear+Redraw (bewusst so belassen -- durch echte Nutzerinteraktion
-- begrenzt, nicht durch Netzwerk-Spam wie beim aeusseren Render-Pfad,
-- daher fuer Phase 3 kein Problem). NUR der zentrale Render-Pfad
-- (core/ui_router.lua -> hier durchgereicht) uebergibt den echten
-- should_clear-Wert und kann das Clearing dadurch gezielt unterdruecken.
-- Das vollstaendige Entfernen des direkten _redraw()-Pfads (UI-P0.7) ist
-- expliziter Phase-4-Umfang im Dokument, hier bewusst noch nicht
-- angefasst.
function M:render(target, ui, colors, should_clear)
  if should_clear == nil then should_clear = true end
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local u = self._ui
  local page_status = u.save.state == "FAILED" and "WARNING" or (u.mode == "edit" and u.dirty and "LIMITED" or "OK")
  if should_clear then mux.clear(target) end
  mux.header(target, { title = "REDSTONE ROUTING", node_id = "FUEL NODE", page = "4/4", status = page_status, icon = "network" })
  self:_render_mode_tabs(target, ui, w)
  if u.mode == "edit" then self:_render_edit(target, ui, w, h) else self:_render_tree(target, ui, w, h) end
  return mux.footer_nav(target, h, w, { center = u.mode == "tree" and "ROUTING TREE" or "ROUTER EDIT" })
end

function M:handle_touch(x, y)
  local u = self._ui
  local function hit(b) return b and y == b.y and x >= b.x1 and x <= b.x2 end

  if hit(u.tree_btn) then
    u.mode = "tree"
    return true
  end
  if hit(u.edit_btn) then
    u.mode = "edit"
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

  if hit(u.save_btn) then
    self:_do_save()
    return true
  end
  if hit(u.reset_btn) then
    u.routes = {}
    u.selected_side = nil
    u.selected_int = nil
    u.dirty = true
    return true
  end
  for _, btn in ipairs(u.side_btns or {}) do
    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
      if u.selected_side == btn.side and u.selected_int == btn.integrator then
        self:_remove(btn.side, btn.integrator)
        u.selected_side = nil
        u.selected_int = nil
      else
        u.selected_side = btn.side
        u.selected_int = btn.integrator
      end
      return true
    end
  end
  if u.selected_side then
    for _, btn in ipairs(u.reactor_btns or {}) do
      if y == btn.y and x >= btn.x1 and x <= btn.x2 then
        self:_assign(u.selected_side, u.selected_int, btn.id, btn.label)
        u.selected_side = nil
        u.selected_int = nil
        return true
      end
    end
  end
  return false
end

-- Fix (2026-07-11): CRITICAL, UI-P0.8. Kompletter Neuaufbau des Save-
-- Ablaufs. Vorher: in fuel_routes.lua UND (getrennt, ohne Validierung)
-- direkt in redstone_tree geschrieben, ohne jede Rueckversicherung dass
-- das Ergebnis tatsaechlich gueltig ist -- ein kaputter Baum wurde
-- erst beim naechsten refresh_peripherals()-Zyklus des Routers bemerkt
-- (siehe redstone_router.lua refresh(), block_all() bei Ungueltigkeit),
-- nicht sofort hier beim Speichern selbst. Jetzt: 1) redstone_tree direkt
-- aus den Editor-Routes bauen, 2) mit derselben validate_tree()-Funktion
-- pruefen, die auch der Router selbst beim naechsten refresh() verwenden
-- wuerde, 3) NUR bei gueltigem Ergebnis tatsaechlich committen + Router
-- aktualisieren, 4) expliziten Save-Zustand setzen (SAVED/FAILED mit
-- genauem Fehler), den die Seite anzeigen kann, statt nur eines
-- Boolean-Logeintrags.
function M:_do_save()
  local u = self._ui
  u.save.state = "SAVING"

  local new_tree = {}
  for _, r in ipairs(u.routes) do
    new_tree[#new_tree + 1] = { side = r.side, label = r.label, reactor = r.reactor, integrator = r.integrator }
  end

  local redstone_router_lib = self.redstone_router and self.redstone_router.validate_tree
    and self.redstone_router or nil
  if redstone_router_lib then
    local validation = redstone_router_lib.validate_tree(new_tree)
    if not validation.ok then
      local first_err = validation.errors[1]
      u.save.state = "FAILED"
      u.save.error = first_err and ("[" .. first_err.code .. "] " .. first_err.message) or "unbekannter Validierungsfehler"
      u.save.saved_at = nil
      self.log("WARN", "RouterUI: Speichern abgelehnt (Validierung fehlgeschlagen): " .. tostring(u.save.error))
      return false
    end
  end

  local ok = save_routes(u.routes, self.config_path)
  if not ok then
    u.save.state = "FAILED"
    u.save.error = "Datei-Schreibfehler (" .. tostring(self.config_path) .. ")"
    self.log("WARN", "RouterUI: failed to save routes to " .. tostring(self.config_path))
    return false
  end

  if self.redstone_router then
    local cfg = self.redstone_router.config
    local lg = cfg.logistics or cfg
    lg.redstone_tree = new_tree
    self.redstone_router:refresh()
    -- Fix (2026-07-11): UI-P0.8. Nach dem Schreiben den operativen
    -- Zustand ZURUECKLESEN statt blind anzunehmen, dass er dem gerade
    -- Geschriebenen entspricht -- validate_tree() innerhalb von refresh()
    -- koennte theoretisch etwas anderes ergeben (z.B. falls refresh()
    -- selbst weitere Normalisierung vornimmt). So bleibt "AKTIV" in der
    -- UI immer eine echte Aussage ueber den tatsaechlichen Router-Zustand.
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

return M
