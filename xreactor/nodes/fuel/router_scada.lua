-- nodes/fuel/router_scada.lua
--
-- Complete native 82x40 rewrite of the FUEL Router presentation.
--
-- Existing router_ui.lua remains authoritative for state, save/discard,
-- logistics toggles, reactor learning, chest selection and valve path edits.
-- This module only paints controls and publishes the exact visible rectangles
-- into the existing _ui fields consumed by those handlers.
--
-- Geometry rules:
--   * toolbar controls are 2 rows high with explicit gaps
--   * row actions are 1 row high and never touch neighboring rows
--   * steppers use small 6x2 +/- controls inside framed cards
--   * page actions end by row 34; rows 36..37 are always clear
--   * shared page footer begins at row 38

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")

local TARGET_W = 82
local TARGET_H = 40
local LIST_PER_PAGE = 8
local PICKER_VISIBLE = 8
local PATH_VISIBLE = 7
local VALVE_VISIBLE = 7

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function nonempty_string(v) return type(v) == "string" and v ~= "" end
local function path_count(r) return type(r) == "table" and type(r.path) == "table" and #r.path or 0 end

local function clear_rect_refs(u)
  u.list_scroll_up, u.list_scroll_down = nil, nil
  u.reactor_btns = {}
  u.learn_btn, u.save_btn, u.reset_btn = nil, nil, nil
  u.export_chest_btn, u.logistics_btn = nil, nil
  u.learn_scroll_up, u.learn_scroll_down = nil, nil
  u.learn_btns, u.learn_cancel_btn = {}, nil
  u.path_row = nil
  u.request_below_minus, u.request_below_plus = nil, nil
  u.fill_amount_minus, u.fill_amount_plus = nil, nil
  u.min_in_me_minus, u.min_in_me_plus = nil, nil
  u.cooldown_minus, u.cooldown_plus = nil, nil
  u.edit_done_btn, u.edit_cancel_btn, u.edit_delete_btn = nil, nil, nil
  u.chest_scroll_up, u.chest_scroll_down = nil, nil
  u.chest_btns, u.chest_cancel_btn = {}, nil
  u.path_scroll_up, u.path_scroll_down = nil, nil
  u.picker_scroll_up, u.picker_scroll_down = nil, nil
  u.step_btns, u.integrator_btns = {}, {}
  u.path_done_btn, u.path_cancel_btn, u.path_clear_btn = nil, nil, nil
  u.teach_btn = nil
end

local function draw_size_error(target, w, h)
  mux.clear(target)
  mux.header(target, {
    title = "FUEL ROUTER", node_id = "FUEL", page = "82x40",
    status = "WARNING", icon = "warning",
  })
  mux.card(target, 8, 8, math.max(30, math.min((w or TARGET_W) - 14, 66)), 12,
    { title = "MONITOR-GROESSE FALSCH", status = "WARNING", icon = "warning" })
end

local function reactor_status(r)
  return path_count(r) > 0 and "OK" or "WARNING"
end

local function reactor_summary(r)
  local req = math.floor((tonumber(r.request_below) or 0.25) * 100 + 0.5)
  local fill = math.floor(tonumber(r.fill_amount) or 64)
  local min_me = math.floor(tonumber(r.min_in_me) or 32)
  local cooldown = math.floor(tonumber(r.resupply_cooldown_s) or 30)
  return string.format("<%d%%  %d  ME%d  %ds  R%d", req, fill, min_me, cooldown, path_count(r))
end

local function save_state_label(self, u)
  if self.routing_load_status and self.routing_load_status.ok == false then return "ROUTING UNGUELTIG", "WARNING" end
  if u.save.state == "FAILED" then return "SPEICHERFEHLER", "WARNING" end
  if u.save.state == "SAVING" then return "WIRD GESPEICHERT", "LIMITED" end
  if u.dirty then return "UNGESPEICHERT", "LIMITED" end
  return "GESPEICHERT / AKTIV", "OK"
end

local function draw_header_state(target, self, u, left_label)
  local ready = 0
  for _, reactor in ipairs(u.reactors or {}) do
    if path_count(reactor) > 0 then ready = ready + 1 end
  end
  local fleet_key = ready == #(u.reactors or {}) and ready > 0 and "OK" or "WARNING"
  mux.status_dot(target, 2, 3,
    left_label or string.format("REAKTOREN %d/%d BEREIT", ready, #(u.reactors or {})),
    fleet_key, 35)
  local save_label, save_key = save_state_label(self, u)
  mux.status_dot(target, 43, 3, save_label, save_key, 38)
end

local function top_controls(target, u)
  u.logistics_btn = mux.button(target, 3, 5, 14,
    u.logistics_enabled and "LOGISTIK AN" or "LOGISTIK AUS",
    u.logistics_enabled and "OK" or "WARNING", 1)
  local chest_label = nonempty_string(u.export_chest)
    and ("EXPORT " .. tostring(u.export_chest)) or "EXPORT NICHT GESETZT"
  u.export_chest_btn = mux.button(target, 19, 5, 36, chest_label,
    nonempty_string(u.export_chest) and "LIMITED" or "WARNING", 1)
  u.learn_btn = mux.button(target, 58, 5, 22, "+ REAKTOR", "LIMITED", 1)
end

local function draw_list(self, target, w, _h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, self, u)
  top_controls(target, u)

  mux.card(target, 2, 8, 79, 23, {
    title = "REAKTOR ROUTEN", status = #u.reactors > 0 and "OK" or "WARNING", icon = "reactor",
  })
  mux.table_header(target, 4, 9, 75, {
    { label = "#", width = 4 }, { label = "REAKTOR", width = 20 },
    { label = "SCHWELLE / MENGE / ME / COOL / ROUTE", width = 43 },
    { label = "", width = 8 },
  })

  local page_count = math.max(1, math.ceil(#u.reactors / LIST_PER_PAGE))
  u.list_scroll = clamp(u.list_scroll, 0, page_count - 1)
  local first = u.list_scroll * LIST_PER_PAGE + 1
  local last = math.min(#u.reactors, first + LIST_PER_PAGE - 1)

  if #u.reactors == 0 then
    mux.warning_box(target, 7, 14, 69,
      { "Keine Reaktoren konfiguriert.", "+ REAKTOR antippen." }, "WARNING")
  else
    local y = 11
    for idx = first, last do
      local r = u.reactors[idx]
      local key = reactor_status(r)
      local name = tostring(r.label or r.reactor_id or ("Reaktor " .. tostring(idx)))
      mux.text(target, 4, y, string.format("%02d", idx), colorset.get(key), colorset.get("background"))
      mux.text(target, 8, y, mux.fit(name, 19), colorset.get(key), colorset.get("background"))
      mux.text(target, 28, y, mux.fit(reactor_summary(r), 41),
        colorset.get(key == "OK" and "muted" or "WARNING"), colorset.get("background"))
      local btn = mux.button(target, 72, y, 7, "EDIT", "LIMITED", 1)
      btn.reactor_id = r.reactor_id
      u.reactor_btns[#u.reactor_btns + 1] = btn
      y = y + 2
    end
  end

  if page_count > 1 then
    if u.list_scroll > 0 then
      u.list_scroll_up = mux.button(target, 5, 28, 11, "<< SEITE", "LIMITED", 1)
    end
    if u.list_scroll < page_count - 1 then
      u.list_scroll_down = mux.button(target, 67, 28, 11, "SEITE >>", "LIMITED", 1)
    end
    local txt = string.format("SEITE %d/%d  %d-%d VON %d", u.list_scroll + 1, page_count, first, last, #u.reactors)
    mux.text(target, math.floor((w - #txt) / 2) + 1, 28, txt,
      colorset.get("muted"), colorset.get("background"))
  end

  u.save_btn = mux.button(target, 24, 33, 15,
    u.dirty and "SPEICHERN *" or "SPEICHERN",
    u.dirty and "LIMITED" or "OK", 2)
  u.reset_btn = mux.button(target, 44, 33, 15, "VERWERFEN", "OFFLINE", 2)
end

local function stepper_card(target, x, y, w, label, value, minus_label, plus_label)
  mux.card(target, x, y, w, 6, { title = label, status = "LIMITED", icon = "config" })
  local button_w = 6
  local by = y + 3
  local minus = mux.button(target, x + 2, by, button_w, minus_label, "LIMITED", 1)
  local plus_x = x + w - 2 - button_w
  local plus = mux.button(target, plus_x, by, button_w, plus_label, "LIMITED", 1)
  local center_x = x + 10
  local center_w = math.max(3, plus_x - center_x - 1)
  local text = tostring(value)
  mux.text(target, center_x + math.max(0, math.floor((center_w - #text) / 2)), by,
    mux.fit(text, center_w), colorset.get("OK"), colorset.get("background"))
  return minus, plus
end

local function draw_edit(self, target, _w, _h)
  local u = self._ui
  clear_rect_refs(u)
  local editing = u.editing
  if not editing then u.mode = "list"; return draw_list(self, target, TARGET_W, TARGET_H) end
  draw_header_state(target, self, u,
    "REAKTOR BEARBEITEN: " .. tostring(editing.label or editing.reactor_id or "?"))

  local pc = path_count(editing)
  local route_label = pc > 0 and ("ROUTE " .. tostring(pc) .. " VENTILE >") or "ROUTE EINRICHTEN >"
  u.path_row = mux.button(target, 22, 5, 39, route_label, pc > 0 and "OK" or "WARNING", 1)

  u.request_below_minus, u.request_below_plus = stepper_card(target, 3, 9, 36,
    "NACHFUELLEN UNTER",
    string.format("%d%%", math.floor((tonumber(editing.request_below) or 0.25) * 100 + 0.5)),
    "-5%", "+5%")
  u.fill_amount_minus, u.fill_amount_plus = stepper_card(target, 44, 9, 35,
    "LIEFERMENGE", tostring(math.floor(tonumber(editing.fill_amount) or 64)) .. " Items",
    "-8", "+8")
  u.min_in_me_minus, u.min_in_me_plus = stepper_card(target, 3, 16, 36,
    "ME MINIMUM", tostring(math.floor(tonumber(editing.min_in_me) or 32)) .. " Items",
    "-8", "+8")
  u.cooldown_minus, u.cooldown_plus = stepper_card(target, 44, 16, 35,
    "ABKLINGZEIT", tostring(math.floor(tonumber(editing.resupply_cooldown_s) or 30)) .. "s",
    "-5s", "+5s")

  mux.card(target, 3, 23, 76, 6, { title = "SCADA HINWEIS", status = "LIMITED", icon = "config" })
  mux.text(target, 6, 25,
    mux.fit("Aenderungen: FERTIG -> danach SPEICHERN.", 70),
    colorset.get("muted"), colorset.get("background"))
  mux.text(target, 6, 27,
    mux.fit("Abklingzeit verhindert Nachlegen waehrend Fuel unterwegs ist.", 70),
    colorset.get("muted"), colorset.get("background"))

  u.edit_done_btn = mux.button(target, 18, 31, 14, "FERTIG", "OK", 2)
  u.edit_delete_btn = mux.button(target, 35, 31, 13, "LOESCHEN", "WARNING", 2)
  u.edit_cancel_btn = mux.button(target, 52, 31, 15, "ABBRECHEN", "OFFLINE", 2)
end

local function learnable_reactors(self)
  local known = {}
  for _, r in ipairs(self._ui.reactors or {}) do
    if r.reactor_id then known[r.reactor_id] = true end
  end
  local out = {}
  for _, c in ipairs(self.get_reactors and self.get_reactors() or {}) do
    if c.id and not known[c.id] then out[#out + 1] = c end
  end
  return out
end

local function scroll_nav(target, u, prefix, offset, total, visible, y)
  local max_scroll = math.max(0, total - visible)
  offset = clamp(offset, 0, max_scroll)
  if offset > 0 then
    u[prefix .. "_scroll_up"] = mux.button(target, 5, y, 12, "<< ZURUECK", "LIMITED", 1)
  end
  if offset < max_scroll then
    u[prefix .. "_scroll_down"] = mux.button(target, 66, y, 12, "WEITER >>", "LIMITED", 1)
  end
  local last = math.min(total, offset + visible)
  local txt = string.format("%d-%d VON %d", total == 0 and 0 or offset + 1, last, total)
  mux.text(target, math.floor((TARGET_W - #txt) / 2) + 1, y, txt,
    colorset.get("muted"), colorset.get("background"))
  return offset
end

local function draw_learn(self, target, _w, _h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, self, u, "REAKTOR EINLERNEN")
  local candidates = learnable_reactors(self)
  mux.card(target, 2, 5, 79, 26, {
    title = "AKTIVE RT-MELDUNGEN", status = #candidates > 0 and "OK" or "WARNING", icon = "network",
  })
  u.learn_scroll = clamp(u.learn_scroll, 0, math.max(0, #candidates - PICKER_VISIBLE))
  local y = 8
  for i = u.learn_scroll + 1, math.min(#candidates, u.learn_scroll + PICKER_VISIBLE) do
    local c = candidates[i]
    local label = tostring(c.label or c.id or "?")
    mux.text(target, 5, y, mux.fit(label, 28), colorset.get("text"), colorset.get("background"))
    mux.text(target, 35, y, mux.fit(tostring(c.id or ""), 30), colorset.get("muted"), colorset.get("background"))
    local btn = mux.button(target, 68, y, 11, "EINLERNEN", "OK", 1)
    btn.id, btn.label = c.id, c.label
    u.learn_btns[#u.learn_btns + 1] = btn
    y = y + 2
  end
  if #candidates == 0 then
    mux.warning_box(target, 8, 12, 66, { "Keine unbekannten Reaktoren per Funk erreichbar." }, "WARNING")
  end
  u.learn_scroll = scroll_nav(target, u, "learn", u.learn_scroll, #candidates, PICKER_VISIBLE, 28)
  u.learn_cancel_btn = mux.button(target, 34, 33, 15, "ABBRECHEN", "OFFLINE", 2)
end

local EXCLUDED = { monitor = true, modem = true }
local function peripheral_names()
  local out = {}
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then return out end
  for _, name in ipairs(peripheral.getNames() or {}) do
    local kind = type(peripheral.getType) == "function" and peripheral.getType(name) or nil
    if not EXCLUDED[kind] then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function draw_chest_pick(self, target, _w, _h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, self, u, "EXPORT-KISTE WAEHLEN")
  local names = peripheral_names()
  mux.card(target, 2, 5, 79, 26, {
    title = "ERKANNTE PERIPHERALS", status = #names > 0 and "OK" or "WARNING", icon = "output",
  })
  u.chest_scroll = clamp(u.chest_scroll, 0, math.max(0, #names - PICKER_VISIBLE))
  local y = 8
  for i = u.chest_scroll + 1, math.min(#names, u.chest_scroll + PICKER_VISIBLE) do
    local name = names[i]
    mux.text(target, 5, y, mux.fit(name, 60), colorset.get("text"), colorset.get("background"))
    local btn = mux.button(target, 68, y, 11, "WAEHLEN", "OK", 1)
    btn.name = name
    u.chest_btns[#u.chest_btns + 1] = btn
    y = y + 2
  end
  if #names == 0 then
    mux.warning_box(target, 8, 12, 66, { "Keine geeigneten Peripherals erkannt." }, "WARNING")
  end
  u.chest_scroll = scroll_nav(target, u, "chest", u.chest_scroll, #names, PICKER_VISIBLE, 28)
  u.chest_cancel_btn = mux.button(target, 34, 33, 15, "ABBRECHEN", "OFFLINE", 2)
end

local function known_valves(self)
  local out = {}
  local rr = self.redstone_router
  if not rr or not rr.comms or type(rr.comms.get_peers) ~= "function" then return out end
  local ok, peers = pcall(rr.comms.get_peers, rr.comms)
  if not ok or type(peers) ~= "table" then return out end
  for id, data in pairs(peers) do
    if type(data) == "table" and data.down ~= true and data.role == constants.roles.VALVE_NODE then
      out[#out + 1] = { id = id, label = tostring(data.label or id) }
    end
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

local function valve_label(self, id)
  for _, v in ipairs(known_valves(self)) do
    if v.id == id then return v.label end
  end
  return tostring(id)
end

local function draw_path(self, target, _w, _h)
  local u = self._ui
  clear_rect_refs(u)
  local editing = u.editing
  if not editing then u.mode = "list"; return draw_list(self, target, TARGET_W, TARGET_H) end
  draw_header_state(target, self, u,
    "VENTILKETTE: " .. tostring(editing.label or editing.reactor_id or "?"))

  u.teach_btn = mux.button(target, 24, 5, 35,
    u.teaching and "EINLERNEN AN" or "EINLERNEN AKTIVIEREN",
    u.teaching and "OK" or "LIMITED", 1)

  mux.card(target, 2, 8, 38, 23, {
    title = "AKTUELLE KETTE", status = path_count(editing) > 0 and "OK" or "WARNING", icon = "network",
  })
  mux.card(target, 43, 8, 38, 23, {
    title = "VENTIL ANFUEGEN", status = "LIMITED", icon = "output",
  })

  u.path_scroll = clamp(u.path_scroll, 0, math.max(0, path_count(editing) - PATH_VISIBLE))
  local py = 11
  for i = u.path_scroll + 1, math.min(path_count(editing), u.path_scroll + PATH_VISIBLE) do
    local id = editing.path[i]
    mux.text(target, 4, py, mux.fit(tostring(i) .. ". " .. valve_label(self, id), 29),
      colorset.get("text"), colorset.get("background"))
    local btn = mux.button(target, 35, py, 3, "X", "WARNING", 1)
    btn.index = i
    u.step_btns[#u.step_btns + 1] = btn
    py = py + 2
  end
  if path_count(editing) == 0 then
    mux.text(target, 4, 12, "(noch kein Ventil)", colorset.get("muted"), colorset.get("background"))
  end

  local valves = known_valves(self)
  u.picker_scroll = clamp(u.picker_scroll, 0, math.max(0, #valves - VALVE_VISIBLE))
  local vy = 11
  for i = u.picker_scroll + 1, math.min(#valves, u.picker_scroll + VALVE_VISIBLE) do
    local v = valves[i]
    mux.text(target, 45, vy, mux.fit(v.label, 29), colorset.get("text"), colorset.get("background"))
    local btn = mux.button(target, 76, vy, 3, "+", "OK", 1)
    btn.integrator = v.id
    u.integrator_btns[#u.integrator_btns + 1] = btn
    vy = vy + 2
  end
  if #valves == 0 then
    mux.text(target, 45, 12, "(keine VALVE-Nodes online)", colorset.get("WARNING"), colorset.get("background"))
  end

  if u.path_scroll > 0 then
    u.path_scroll_up = mux.button(target, 5, 28, 10, "<< KETTE", "LIMITED", 1)
  end
  if u.path_scroll < math.max(0, path_count(editing) - PATH_VISIBLE) then
    u.path_scroll_down = mux.button(target, 28, 28, 10, "KETTE >>", "LIMITED", 1)
  end
  if u.picker_scroll > 0 then
    u.picker_scroll_up = mux.button(target, 46, 28, 10, "<< LISTE", "LIMITED", 1)
  end
  if u.picker_scroll < math.max(0, #valves - VALVE_VISIBLE) then
    u.picker_scroll_down = mux.button(target, 69, 28, 10, "LISTE >>", "LIMITED", 1)
  end

  u.path_done_btn = mux.button(target, 18, 32, 14, "FERTIG", "OK", 2)
  u.path_clear_btn = mux.button(target, 35, 32, 13, "LEEREN", "WARNING", 2)
  u.path_cancel_btn = mux.button(target, 52, 32, 15, "ABBRECHEN", "OFFLINE", 2)
end

function M.attach(router)
  if type(router) ~= "table" then return router end
  if router._scada_rewrite_attached then return router end
  router._scada_rewrite_attached = true

  router._render_list = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then clear_rect_refs(self._ui); return draw_size_error(target, w, h) end
    return draw_list(self, target, w, h)
  end
  router._render_edit = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then clear_rect_refs(self._ui); return draw_size_error(target, w, h) end
    return draw_edit(self, target, w, h)
  end
  router._render_learn = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then clear_rect_refs(self._ui); return draw_size_error(target, w, h) end
    return draw_learn(self, target, w, h)
  end
  router._render_chest_pick = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then clear_rect_refs(self._ui); return draw_size_error(target, w, h) end
    return draw_chest_pick(self, target, w, h)
  end
  router._render_path = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then clear_rect_refs(self._ui); return draw_size_error(target, w, h) end
    return draw_path(self, target, w, h)
  end
  return router
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.LIST_PER_PAGE = LIST_PER_PAGE
M.PICKER_VISIBLE = PICKER_VISIBLE
M.PATH_VISIBLE = PATH_VISIBLE
M.VALVE_VISIBLE = VALVE_VISIBLE

return M
