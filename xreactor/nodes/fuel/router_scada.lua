-- nodes/fuel/router_scada.lua
--
-- Fixed 82x40 SCADA renderer for every FUEL router mode.
-- Reuses router_ui.lua's existing state, persistence and touch handlers.
-- This revision reduces oversized buttons and evens out spacing while keeping
-- the exact visible rectangle as the touch rectangle returned by mux.button().
--
-- Presentation only: no save/logistics/valve-control logic is duplicated here.

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
  clear_rect_refs((target and target._ui) or {})
  mux.clear(target)
  mux.header(target, {
    title = "FUEL ROUTER", node_id = "FUEL", page = "82x40",
    status = "WARNING", icon = "warning",
  })
  mux.card(target, 5, 8, math.max(20, math.min((w or TARGET_W) - 8, 72)), 12,
    { title = "MONITOR-GROESSE FALSCH", status = "WARNING", icon = "warning" })
end

local function reactor_status(r)
  if path_count(r) == 0 then return "WARNING" end
  return "OK"
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

local function draw_header_state(target, w, self, u, left_label)
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

-- Smaller two-row toolbar; the old 3-row full-width blocks dominated the page.
local function draw_top_controls(target, u)
  u.logistics_btn = mux.button(target, 2, 5, 14,
    u.logistics_enabled and "LOGISTIK AN" or "LOGISTIK AUS",
    u.logistics_enabled and "OK" or "WARNING", 2)
  local chest_label = nonempty_string(u.export_chest)
    and ("EXPORT " .. tostring(u.export_chest)) or "EXPORT NICHT GESETZT"
  u.export_chest_btn = mux.button(target, 18, 5, 35, chest_label,
    nonempty_string(u.export_chest) and "LIMITED" or "WARNING", 2)
  u.learn_btn = mux.button(target, 57, 5, 22, "+ REAKTOR", "LIMITED", 2)
end

local function draw_list(self, target, w, h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, w, self, u)
  draw_top_controls(target, u)

  mux.card(target, 2, 8, 79, 25, {
    title = "REAKTOR ROUTEN", status = #u.reactors > 0 and "OK" or "WARNING", icon = "reactor",
  })
  mux.table_header(target, 4, 9, 75, {
    { label = "#", width = 4 },
    { label = "REAKTOR", width = 20 },
    { label = "SCHWELLE / MENGE / ME / COOL / ROUTE", width = 41 },
    { label = "AKTION", width = 10 },
  })

  local page_count = math.max(1, math.ceil(#u.reactors / LIST_PER_PAGE))
  u.list_scroll = clamp(u.list_scroll, 0, page_count - 1)
  local first = u.list_scroll * LIST_PER_PAGE + 1
  local last = math.min(#u.reactors, first + LIST_PER_PAGE - 1)

  if #u.reactors == 0 then
    mux.warning_box(target, 5, 14, 73,
      { "Keine Reaktoren konfiguriert.", "+ REAKTOR antippen." }, "WARNING")
  else
    local y = 12
    for idx = first, last do
      local r = u.reactors[idx]
      local key = reactor_status(r)
      local name = tostring(r.label or r.reactor_id or ("Reaktor " .. tostring(idx)))
      mux.text(target, 4, y, string.format("%02d", idx), colorset.get(key), colorset.get("background"))
      mux.text(target, 8, y, mux.fit(name, 19), colorset.get(key), colorset.get("background"))
      mux.text(target, 28, y, mux.fit(reactor_summary(r), 39),
        colorset.get(key == "OK" and "muted" or "WARNING"), colorset.get("background"))
      local btn = mux.button(target, 70, y, 9, "EDIT >", "LIMITED", 2)
      btn.reactor_id = r.reactor_id
      u.reactor_btns[#u.reactor_btns + 1] = btn
      y = y + 2
    end
  end

  local nav_y = 29
  if page_count > 1 then
    if u.list_scroll > 0 then
      u.list_scroll_up = mux.button(target, 5, nav_y, 12, "<< SEITE", "LIMITED", 2)
    end
    if u.list_scroll < page_count - 1 then
      u.list_scroll_down = mux.button(target, 66, nav_y, 12, "SEITE >>", "LIMITED", 2)
    end
    local txt = string.format("SEITE %d/%d  %d-%d VON %d", u.list_scroll + 1, page_count, first, last, #u.reactors)
    mux.text(target, math.floor((w - #txt) / 2) + 1, nav_y + 1, txt,
      colorset.get("muted"), colorset.get("background"))
  end

  u.save_btn = mux.button(target, 22, 33, 18,
    u.dirty and "SPEICHERN *" or "SPEICHERN",
    u.dirty and "LIMITED" or "OK", 2)
  u.reset_btn = mux.button(target, 44, 33, 16, "VERWERFEN", "OFFLINE", 2)
end

-- Compact stepper: label above, two small buttons around a centered value.
local function compact_stepper(target, x, y, w, label, value, minus_label, plus_label)
  local button_w = 7
  mux.text(target, x, y, mux.fit(label, w), colorset.get("muted"), colorset.get("background"))
  local minus = mux.button(target, x, y + 1, button_w, minus_label, "LIMITED", 2)
  local plus_x = x + w - button_w
  local plus = mux.button(target, plus_x, y + 1, button_w, plus_label, "LIMITED", 2)
  local center_x = x + button_w + 1
  local center_w = math.max(3, plus_x - center_x - 1)
  local text = tostring(value)
  mux.text(target, center_x + math.max(0, math.floor((center_w - #text) / 2)), y + 1,
    mux.fit(text, center_w), colorset.get("OK"), colorset.get("background"))
  return minus, plus
end

local function draw_edit(self, target, w, h)
  local u = self._ui
  clear_rect_refs(u)
  local editing = u.editing
  if not editing then u.mode = "list"; return draw_list(self, target, w, h) end
  draw_header_state(target, w, self, u,
    "REAKTOR BEARBEITEN: " .. tostring(editing.label or editing.reactor_id or "?"))

  local pc = path_count(editing)
  local route_label = pc > 0
    and ("ROUTE " .. tostring(pc) .. " VENTILE  >") or "ROUTE EINRICHTEN >"
  u.path_row = mux.button(target, 17, 5, 48, route_label, pc > 0 and "OK" or "WARNING", 2)

  u.request_below_minus, u.request_below_plus = compact_stepper(target, 3, 9, 36,
    "NACHFUELLEN UNTER",
    string.format("%d%%", math.floor((tonumber(editing.request_below) or 0.25) * 100 + 0.5)),
    "-5%", "+5%")
  u.fill_amount_minus, u.fill_amount_plus = compact_stepper(target, 44, 9, 35,
    "LIEFERMENGE",
    tostring(math.floor(tonumber(editing.fill_amount) or 64)) .. " Items",
    "-8", "+8")
  u.min_in_me_minus, u.min_in_me_plus = compact_stepper(target, 3, 14, 36,
    "ME MINIMUM",
    tostring(math.floor(tonumber(editing.min_in_me) or 32)) .. " Items",
    "-8", "+8")
  u.cooldown_minus, u.cooldown_plus = compact_stepper(target, 44, 14, 35,
    "ABKLINGZEIT",
    tostring(math.floor(tonumber(editing.resupply_cooldown_s) or 30)) .. "s",
    "-5s", "+5s")

  mux.card(target, 3, 19, 76, 9, { title = "SCADA HINWEIS", status = "LIMITED", icon = "config" })
  mux.text(target, 5, 21,
    mux.fit("Aenderungen gelten erst nach FERTIG und anschliessendem SPEICHERN.", 72),
    colorset.get("muted"), colorset.get("background"))
  mux.text(target, 5, 23,
    mux.fit("ABKLINGZEIT verhindert Nachlegen, solange Fuel noch unterwegs ist.", 72),
    colorset.get("muted"), colorset.get("background"))
  mux.text(target, 5, 25,
    mux.fit("Route: " .. (pc > 0 and (tostring(pc) .. " Ventile") or "nicht konfiguriert"), 72),
    colorset.get(pc > 0 and "OK" or "WARNING"), colorset.get("background"))

  u.edit_done_btn = mux.button(target, 15, 31, 16, "FERTIG", "OK", 2)
  u.edit_delete_btn = mux.button(target, 35, 31, 13, "LOESCHEN", "WARNING", 2)
  u.edit_cancel_btn = mux.button(target, 52, 31, 16, "ABBRECHEN", "OFFLINE", 2)
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

local function draw_scroll_nav(target, u, prefix, offset, total, visible, y)
  local max_scroll = math.max(0, total - visible)
  offset = clamp(offset, 0, max_scroll)
  if offset > 0 then
    u[prefix .. "_scroll_up"] = mux.button(target, 5, y, 12, "<< ZURUECK", "LIMITED", 2)
  end
  if offset < max_scroll then
    u[prefix .. "_scroll_down"] = mux.button(target, 66, y, 12, "WEITER >>", "LIMITED", 2)
  end
  local last = math.min(total, offset + visible)
  local txt = string.format("%d-%d VON %d", total == 0 and 0 or offset + 1, last, total)
  mux.text(target, math.floor((TARGET_W - #txt) / 2) + 1, y + 1, txt,
    colorset.get("muted"), colorset.get("background"))
  return offset, max_scroll
end

local function draw_learn(self, target, w, h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, w, self, u, "REAKTOR EINLERNEN")
  local candidates = learnable_reactors(self)
  mux.card(target, 2, 5, 79, 28, {
    title = "AKTIVE RT-MELDUNGEN", status = #candidates > 0 and "OK" or "WARNING", icon = "network",
  })
  u.learn_scroll = clamp(u.learn_scroll, 0, math.max(0, #candidates - PICKER_VISIBLE))
  local y = 8
  for i = u.learn_scroll + 1, math.min(#candidates, u.learn_scroll + PICKER_VISIBLE) do
    local c = candidates[i]
    local label = tostring(c.label or c.id or "?")
    mux.data_row(target, 4, y, 61, {
      label = label, value = tostring(c.id or ""), status = "OK", icon = "reactor",
    })
    local btn = mux.button(target, 67, y, 12, "EINLERNEN", "OK", 2)
    btn.id, btn.label = c.id, c.label
    u.learn_btns[#u.learn_btns + 1] = btn
    y = y + 2
  end
  if #candidates == 0 then
    mux.warning_box(target, 5, 11, 73, { "Keine unbekannten Reaktoren per Funk erreichbar." }, "WARNING")
  end
  u.learn_scroll = select(1, draw_scroll_nav(target, u, "learn",
    u.learn_scroll, #candidates, PICKER_VISIBLE, 28))
  u.learn_cancel_btn = mux.button(target, 33, 33, 16, "ABBRECHEN", "OFFLINE", 2)
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

local function draw_chest_pick(self, target, w, h)
  local u = self._ui
  clear_rect_refs(u)
  draw_header_state(target, w, self, u, "EXPORT-KISTE WAEHLEN")
  local names = peripheral_names()
  mux.card(target, 2, 5, 79, 28, {
    title = "ERKANNTE PERIPHERALS", status = #names > 0 and "OK" or "WARNING", icon = "output",
  })
  u.chest_scroll = clamp(u.chest_scroll, 0, math.max(0, #names - PICKER_VISIBLE))
  local y = 8
  for i = u.chest_scroll + 1, math.min(#names, u.chest_scroll + PICKER_VISIBLE) do
    local name = names[i]
    mux.text(target, 4, y, mux.fit(name, 61), colorset.get("text"), colorset.get("background"))
    local btn = mux.button(target, 67, y, 12, "WAEHLEN", "OK", 2)
    btn.name = name
    u.chest_btns[#u.chest_btns + 1] = btn
    y = y + 2
  end
  if #names == 0 then
    mux.warning_box(target, 5, 11, 73, { "Keine geeigneten Peripherals erkannt." }, "WARNING")
  end
  u.chest_scroll = select(1, draw_scroll_nav(target, u, "chest",
    u.chest_scroll, #names, PICKER_VISIBLE, 28))
  u.chest_cancel_btn = mux.button(target, 33, 33, 16, "ABBRECHEN", "OFFLINE", 2)
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

local function draw_path(self, target, w, h)
  local u = self._ui
  clear_rect_refs(u)
  local editing = u.editing
  if not editing then u.mode = "list"; return draw_list(self, target, w, h) end
  draw_header_state(target, w, self, u,
    "VENTILKETTE: " .. tostring(editing.label or editing.reactor_id or "?"))

  u.teach_btn = mux.button(target, 15, 5, 52,
    u.teaching and "EINLERNEN AN - HEBEL UMLEGEN" or "EINLERNEN AKTIVIEREN",
    u.teaching and "OK" or "LIMITED", 2)

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
    local btn = mux.button(target, 34, py, 4, "X", "WARNING", 2)
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
    local btn = mux.button(target, 75, vy, 4, "+", "OK", 2)
    btn.integrator = v.id
    u.integrator_btns[#u.integrator_btns + 1] = btn
    vy = vy + 2
  end
  if #valves == 0 then
    mux.text(target, 45, 12, "(keine VALVE-Nodes online)",
      colorset.get("WARNING"), colorset.get("background"))
  end

  if u.path_scroll > 0 then
    u.path_scroll_up = mux.button(target, 5, 27, 10, "<< KETTE", "LIMITED", 2)
  end
  if u.path_scroll < math.max(0, path_count(editing) - PATH_VISIBLE) then
    u.path_scroll_down = mux.button(target, 28, 27, 10, "KETTE >>", "LIMITED", 2)
  end
  if u.picker_scroll > 0 then
    u.picker_scroll_up = mux.button(target, 46, 27, 10, "<< LISTE", "LIMITED", 2)
  end
  if u.picker_scroll < math.max(0, #valves - VALVE_VISIBLE) then
    u.picker_scroll_down = mux.button(target, 69, 27, 10, "LISTE >>", "LIMITED", 2)
  end

  u.path_done_btn = mux.button(target, 15, 32, 16, "FERTIG", "OK", 2)
  u.path_clear_btn = mux.button(target, 35, 32, 13, "LEEREN", "WARNING", 2)
  u.path_cancel_btn = mux.button(target, 52, 32, 16, "ABBRECHEN", "OFFLINE", 2)
end

function M.attach(router)
  if type(router) ~= "table" then return router end
  if router._scada_fixed_router_attached then return router end
  router._scada_fixed_router_attached = true

  router._render_list = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then
      clear_rect_refs(self._ui)
      return draw_size_error(target, w, h)
    end
    return draw_list(self, target, w, h)
  end
  router._render_edit = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then
      clear_rect_refs(self._ui)
      return draw_size_error(target, w, h)
    end
    return draw_edit(self, target, w, h)
  end
  router._render_learn = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then
      clear_rect_refs(self._ui)
      return draw_size_error(target, w, h)
    end
    return draw_learn(self, target, w, h)
  end
  router._render_chest_pick = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then
      clear_rect_refs(self._ui)
      return draw_size_error(target, w, h)
    end
    return draw_chest_pick(self, target, w, h)
  end
  router._render_path = function(self, target, w, h)
    if w ~= TARGET_W or h ~= TARGET_H then
      clear_rect_refs(self._ui)
      return draw_size_error(target, w, h)
    end
    return draw_path(self, target, w, h)
  end
  return router
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.LIST_PER_PAGE = LIST_PER_PAGE

return M
