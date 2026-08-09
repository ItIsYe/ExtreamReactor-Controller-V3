local M = {}

local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")

local BUILTIN_SIDES = { "top", "bottom", "left", "right", "front", "back" }

local function step_label(step)
  return tostring(step.side or "-") .. (step.integrator and (" @" .. tostring(step.integrator)) or "")
end

local function path_text(path)
  local parts = {}
  for _, step in ipairs(path or {}) do parts[#parts + 1] = step_label(step) end
  if #parts == 0 then return "KEIN VENTIL" end
  return table.concat(parts, " > ")
end

local function known_valve_ids(router)
  local out = {}
  if not router or not router.comms then return out end
  local ok, peers = pcall(router.comms.get_peers, router.comms)
  if not ok or type(peers) ~= "table" then return out end
  for id, data in pairs(peers) do
    if type(data) == "table" and data.down ~= true and data.role == constants.roles.VALVE_NODE then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function clamp_scroll(value, total, visible)
  visible = math.max(1, tonumber(visible) or 1)
  local max_scroll = math.max(0, (tonumber(total) or 0) - visible)
  value = math.max(0, math.min(tonumber(value) or 0, max_scroll))
  return value, max_scroll
end

local function paging_badges(target, ui, w, y, scroll, max_scroll)
  if max_scroll <= 0 then return nil, nil end
  local up_x = math.max(2, w - 11)
  local dn_x = math.max(7, w - 5)
  ui.badge(target, up_x, y, "UP", scroll > 0 and "LIMITED" or "OFFLINE")
  ui.badge(target, dn_x, y, "DN", scroll < max_scroll and "LIMITED" or "OFFLINE")
  local up = scroll > 0 and { x1 = up_x, x2 = up_x + 3, y = y } or nil
  local down = scroll < max_scroll and { x1 = dn_x, x2 = dn_x + 3, y = y } or nil
  return up, down
end

local function render_list(self, target, ui, w, h)
  local u = self._ui
  local reactors = self.get_reactors()
  mux.status_dot(target, 2, 3, string.format("ROUTEN %d/%d", #u.routes, #reactors), #u.routes > 0 and "OK" or "LIMITED", math.max(8, math.floor(w * 0.33)))

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
  local btn_y = math.max(body_top + 3, h - 2)
  local body_bottom = math.max(body_top + 2, btn_y - 1)
  local body_h = body_bottom - body_top + 1
  mux.card(target, 2, body_top, w - 3, body_h, { title = "REAKTOR ZIELE -- ANTIPPEN ZUM BEARBEITEN", status = #reactors > 0 and "OK" or "WARNING", icon = "reactor" })

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
    mux.warning_box(target, 4, first_y, w - 6, { "Keine Reaktor-Ziele gefunden", "RT-Nodes online oder logistics.reactors konfigurieren" }, "WARNING")
  end

  if max_scroll > 0 then
    ui.text(target, 4, control_y, string.format("%d-%d/%d", u.list_scroll + 1, math.min(#reactors, u.list_scroll + visible), #reactors), colorset.get("muted"), colorset.get("background"))
    u.list_scroll_up, u.list_scroll_down = paging_badges(target, ui, w - 2, control_y, u.list_scroll, max_scroll)
  else
    u.list_scroll_up, u.list_scroll_down = nil, nil
  end

  local save_lbl = u.dirty and "[ SPEICHERN * ]" or "[ SPEICHERN ]"
  local reset_lbl = "[ RESET ]"
  if w < 34 then save_lbl, reset_lbl = u.dirty and "[SAVE*]" or "[SAVE]", "[RST]" end
  mux.data_row(target, 2, btn_y, w - 3, { label = save_lbl, value = reset_lbl, status = u.dirty and "LIMITED" or "OK", icon = "config" })
  u.save_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #save_lbl + 2), y = btn_y }
  u.reset_btn = { x1 = math.max(2, w - #reset_lbl - 2), x2 = w - 1, y = btn_y }
end

local function render_path(self, target, ui, w, h)
  local u = self._ui
  local editing = u.editing
  if not editing then
    u.edit_view = "list"
    return render_list(self, target, ui, w, h)
  end

  mux.banner(target, 2, 3, w - 3, "VENTILKETTE: " .. tostring(editing.label or editing.reactor), "LIMITED", "reactor")

  local teach_lbl = u.teaching and "[ EINLERNEN: AN ]" or "[ EINLERNEN: AUS ]"
  local teach_hint = u.teaching and "Hebel am Ventil umlegen, um es anzuhaengen" or "Antippen zum Aktivieren"
  if w < 40 then
    teach_lbl = u.teaching and "[TEACH ON]" or "[TEACH]"
    teach_hint = u.teaching and "HEBEL" or "ANTIPPEN"
  end
  mux.data_row(target, 2, 4, w - 3, { label = teach_lbl, value = teach_hint, status = u.teaching and "OK" or "muted", icon = "network" })
  u.teach_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #teach_lbl + 1), y = 4 }

  local btn_y = math.max(7, h - 2)
  local content_top = 5
  local content_bottom = math.max(content_top + 3, btn_y - 1)
  local total_body = math.max(4, content_bottom - content_top + 1)
  local chain_h = math.max(2, math.min(7, math.floor(total_body * 0.45)))
  if total_body - chain_h < 2 then chain_h = math.max(2, total_body - 2) end
  local picker_top = content_top + chain_h
  local picker_h = math.max(2, content_bottom - picker_top + 1)

  mux.card(target, 2, content_top, w - 3, chain_h, { title = "AKTUELLE KETTE", status = #editing.path > 0 and "OK" or "LIMITED", icon = "network" })
  local visible_steps = math.max(1, chain_h - 1)
  local path_max_scroll
  u.path_scroll, path_max_scroll = clamp_scroll(u.path_scroll, #editing.path, visible_steps)
  u.path_scroll_up, u.path_scroll_down = paging_badges(target, ui, w - 2, content_top, u.path_scroll, path_max_scroll)

  local step_btns = {}
  local sy = content_top + 1
  for i = u.path_scroll + 1, math.min(#editing.path, u.path_scroll + visible_steps) do
    local step = editing.path[i]
    mux.data_row(target, 4, sy, w - 6, { label = tostring(i) .. ".", value = step_label(step), status = "OK", icon = "output" })
    step_btns[#step_btns + 1] = { x1 = 4, x2 = w - 3, y = sy, index = i }
    sy = sy + 1
  end
  if #editing.path == 0 and sy <= content_top + chain_h - 1 then
    ui.text(target, 4, sy, mux.fit("(noch kein Ventil)", math.max(1, w - 7)), colorset.get("muted"), colorset.get("background"))
  end
  u.step_btns = step_btns

  local side_btns, integrator_btns = {}, {}
  local items = {}
  if u.pending_side then
    mux.banner(target, 2, picker_top, w - 3, "SEITE " .. tostring(u.pending_side):upper() .. " -- ZIEL", "LIMITED", "network")
    items[#items + 1] = { label = "LOKAL", value = "FUEL-NODE", integrator = nil }
    for _, id in ipairs(known_valve_ids(self.redstone_router)) do
      items[#items + 1] = { label = tostring(id), value = "VALVE-NODE", integrator = id }
    end
  else
    mux.card(target, 2, picker_top, w - 3, picker_h, { title = "VENTIL ANFUEGEN", status = "LIMITED", icon = "output" })
    for _, side in ipairs(BUILTIN_SIDES) do items[#items + 1] = { label = tostring(side):upper(), value = "ANTIPPEN", side = side } end
  end

  local visible_picker = math.max(1, picker_h - 1)
  local picker_max_scroll
  u.picker_scroll, picker_max_scroll = clamp_scroll(u.picker_scroll, #items, visible_picker)
  u.picker_scroll_up, u.picker_scroll_down = paging_badges(target, ui, w - 2, picker_top, u.picker_scroll, picker_max_scroll)
  local py = picker_top + 1
  for i = u.picker_scroll + 1, math.min(#items, u.picker_scroll + visible_picker) do
    local item = items[i]
    mux.data_row(target, 4, py, w - 6, { label = item.label, value = item.value, status = "OK", icon = item.integrator and "network" or "output" })
    if u.pending_side then
      integrator_btns[#integrator_btns + 1] = { x1 = 4, x2 = w - 3, y = py, integrator = item.integrator }
    else
      side_btns[#side_btns + 1] = { x1 = 4, x2 = w - 3, y = py, side = item.side }
    end
    py = py + 1
  end
  u.side_btns = side_btns
  u.integrator_btns = integrator_btns

  local done_lbl, clear_lbl, cancel_lbl = "[ FERTIG ]", "[ LEEREN ]", "[ ABBRECHEN ]"
  if w < 40 then done_lbl, clear_lbl, cancel_lbl = "[OK]", "[CLR]", "[X]" end
  mux.data_row(target, 2, btn_y, w - 3, { label = done_lbl, value = clear_lbl .. " " .. cancel_lbl, status = "OK", icon = "config" })
  u.done_btn = { x1 = 2, x2 = math.min(w - 1, 2 + #done_lbl + 1), y = btn_y }
  u.cancel_btn = { x1 = math.max(2, w - #cancel_lbl - 1), x2 = w - 1, y = btn_y }
  u.clear_btn = { x1 = math.max(2, u.cancel_btn.x1 - #clear_lbl - 2), x2 = math.max(2, u.cancel_btn.x1 - 2), y = btn_y }
end

function M.attach(instance)
  if type(instance) ~= "table" or instance._responsive_paging_attached then return instance end
  instance._responsive_paging_attached = true
  local u = instance._ui or {}
  instance._ui = u
  u.list_scroll = tonumber(u.list_scroll) or 0
  u.path_scroll = tonumber(u.path_scroll) or 0
  u.picker_scroll = tonumber(u.picker_scroll) or 0

  instance._render_list = render_list
  instance._render_path = render_path

  local original_handle_touch = instance.handle_touch
  instance.handle_touch = function(self, x, y)
    local state = self._ui
    local function hit(b) return b and y == b.y and x >= b.x1 and x <= b.x2 end

    if hit(state.list_scroll_up) then state.list_scroll = math.max(0, state.list_scroll - 1); return true end
    if hit(state.list_scroll_down) then state.list_scroll = state.list_scroll + 1; return true end
    if hit(state.path_scroll_up) then state.path_scroll = math.max(0, state.path_scroll - 1); return true end
    if hit(state.path_scroll_down) then state.path_scroll = state.path_scroll + 1; return true end
    if hit(state.picker_scroll_up) then state.picker_scroll = math.max(0, state.picker_scroll - 1); return true end
    if hit(state.picker_scroll_down) then state.picker_scroll = state.picker_scroll + 1; return true end

    local before_view = state.edit_view
    local before_pending = state.pending_side
    local consumed = original_handle_touch(self, x, y) == true
    if consumed then
      if before_view ~= state.edit_view and state.edit_view == "path" then
        state.path_scroll, state.picker_scroll = 0, 0
      end
      if before_pending ~= state.pending_side then state.picker_scroll = 0 end
    end
    return consumed
  end

  return instance
end

return M
