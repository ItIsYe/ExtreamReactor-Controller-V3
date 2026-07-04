local M = {}
local mux = require("core.mockup_ui")

local DEFAULT_ROUTE_CONFIG_PATH = "/xreactor/config/fuel_routes.lua"
local BUILTIN_SIDES = { "top", "bottom", "left", "right", "front", "back" }

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
      r.side or "",
      r.reactor or "",
      r.label or r.reactor or "",
      r.integrator and (", integrator = " .. string.format("%q", r.integrator)) or ""
    ))
  end
  f.writeLine("}")
  f.close()
  return true
end

function M.new(opts)
  opts = opts or {}
  local self = {
    redstone_router = opts.redstone_router,
    log = opts.log or function() end,
    get_reactors = opts.get_reactors or function() return {} end,
    config_path = opts.config_path or DEFAULT_ROUTE_CONFIG_PATH,
    _ui = {
      selected_side = nil,
      selected_int = nil,
      routes = {},
      dirty = false,
      side_btns = {},
      reactor_btns = {},
      save_btn = nil,
      reset_btn = nil,
    },
  }
  self._ui.routes = load_routes(self.config_path)
  return setmetatable(self, { __index = M })
end

function M:_find(side, integrator)
  for _, r in ipairs(self._ui.routes) do
    if r.side == side and (r.integrator or nil) == (integrator or nil) then return r end
  end
  return nil
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
    side = side,
    integrator = integrator or nil,
    reactor = reactor_id,
    label = label,
  }
  self._ui.dirty = true
end

function M:render(target, ui, colors)
  local w, h = ui.getSize(target)
  if not w or not h then return end
  local u = self._ui
  local reactors = self.get_reactors()
  local page_status = u.dirty and "LIMITED" or "OK"

  mux.clear(target)
  mux.header(target, { title = "ROUTER CONFIG", node_id = "LOCAL NODE", page = "4/4", status = page_status, icon = "network" })
  mux.status_dot(target, 2, 3, string.format("ROUTEN %d", #u.routes), #u.routes > 0 and "OK" or "LIMITED")
  if w >= 40 then mux.status_dot(target, math.floor(w * 0.38), 3, u.dirty and "UNSAVED" or "SAVED", u.dirty and "LIMITED" or "OK") end
  if w >= 62 then mux.status_dot(target, math.floor(w * 0.70), 3, string.format("ZIELE %d", #reactors), #reactors > 0 and "OK" or "WARNING") end

  local gap = 2
  local left_w = math.floor((w - 4 - gap) / 2)
  local right_x = 2 + left_w + gap
  local right_w = w - right_x - 1
  local body_h = math.max(8, h - 10)

  mux.card(target, 2, 5, left_w, body_h, { title = "REDSTONE AUSGAENGE", status = "LIMITED", icon = "output" })
  mux.card(target, right_x, 5, right_w, body_h, { title = "REAKTOR ZIELE", status = #reactors > 0 and "OK" or "WARNING", icon = "reactor" })

  local side_btns = {}
  local sy = 7
  for i, side in ipairs(BUILTIN_SIDES) do
    if sy > 5 + body_h - 2 then break end
    local assigned = self:_find(side, nil)
    local selected = u.selected_side == side and u.selected_int == nil
    local key = selected and "LIMITED" or assigned and "OK" or "muted"
    local value = assigned and tostring(assigned.label or assigned.reactor or "?") or "FREI"
    mux.data_row(target, 4, sy, left_w - 4, { label = tostring(side):upper(), value = value, status = key, icon = selected and "config" or "output" })
    side_btns[#side_btns + 1] = { x1 = 4, x2 = 1 + left_w - 1, y = sy, side = side, integrator = nil }
    sy = sy + 1
  end
  u.side_btns = side_btns

  local reactor_btns = {}
  local ry = 7
  for _, rx in ipairs(reactors) do
    if ry > 5 + body_h - 2 then break end
    local assigned = false
    for _, route in ipairs(u.routes) do if route.reactor == rx.id then assigned = true; break end end
    local key = assigned and "OK" or "text"
    mux.data_row(target, right_x + 2, ry, right_w - 4, { label = tostring(rx.label or rx.id), value = assigned and "ASSIGNED" or "READY", status = key, icon = "reactor" })
    reactor_btns[#reactor_btns + 1] = { x1 = right_x + 2, x2 = right_x + right_w - 3, y = ry, id = rx.id, label = rx.label or rx.id }
    ry = ry + 1
  end
  u.reactor_btns = reactor_btns

  if #reactors == 0 then
    mux.warning_box(target, right_x + 2, 7, right_w - 4, { "Keine Ziele gefunden", "Discovery pruefen" }, "WARNING")
  end

  if h >= 18 then
    local hint = u.selected_side
      and ("AUSGANG " .. tostring(u.selected_side):upper() .. " GEWAEHLT -> ZIEL ANTIPPEN")
      or "AUSGANG ANTIPPEN -> DANACH ZIEL ANTIPPEN"
    mux.banner(target, 2, h - 4, w - 3, hint, u.selected_side and "LIMITED" or "muted", "network")
  end

  local btn_y = h - 2
  local save_lbl = u.dirty and "[ SPEICHERN * ]" or "[ SPEICHERN ]"
  local reset_lbl = "[ RESET ]"
  mux.data_row(target, 2, btn_y, w - 3, { label = save_lbl, value = reset_lbl, status = u.dirty and "LIMITED" or "OK", icon = "config" })
  u.save_btn = { x1 = 2, x2 = 2 + #save_lbl + 3, y = btn_y }
  u.reset_btn = { x1 = math.max(2, w - #reset_lbl - 2), x2 = w - 1, y = btn_y }
  mux.footer_nav(target, h, w, { left = "AUSGANG", center = "ROUTER CONFIG", right = "ZIEL" })
end

function M:handle_touch(x, y)
  local u = self._ui
  local sb = u.save_btn
  if sb and y == sb.y and x >= sb.x1 and x <= sb.x2 then self:_do_save(); return true end
  local rb = u.reset_btn
  if rb and y == rb.y and x >= rb.x1 and x <= rb.x2 then
    u.routes = {}
    u.selected_side = nil
    u.dirty = true
    return true
  end
  for _, btn in ipairs(u.side_btns) do
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
    for _, btn in ipairs(u.reactor_btns) do
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

function M:_do_save()
  local u = self._ui
  local ok = save_routes(u.routes, self.config_path)
  if ok then
    self.log("INFO", "RouterUI: saved " .. #u.routes .. " routes to " .. tostring(self.config_path))
    u.dirty = false
    if self.redstone_router then
      local cfg = self.redstone_router.config
      local lg = cfg.logistics or cfg
      lg.redstone_tree = {}
      for _, r in ipairs(u.routes) do
        lg.redstone_tree[#lg.redstone_tree + 1] = {
          side = r.side,
          label = r.label,
          reactor = r.reactor,
          integrator = r.integrator,
        }
      end
      self.redstone_router:refresh()
      self.log("INFO", "RouterUI: redstone_router updated with " .. #u.routes .. " routes")
    end
  else
    self.log("WARN", "RouterUI: failed to save routes to " .. tostring(self.config_path))
  end
end

function M:get_routes()
  return self._ui.routes
end

return M
