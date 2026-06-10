-- nodes/fuel/router_ui.lua
--
-- Local router configuration UI for the FUEL node's own monitor.
-- Runs directly on the FUEL computer — no MASTER connection needed.
--
-- Interaction (monitor touch):
--   1. Tap a redstone output side (left column) → SELECTED (yellow)
--   2. Tap a reactor name (right column)        → route ASSIGNED (green)
--   3. Tap an already-selected/assigned side    → REMOVE assignment
--   [Speichern] saves config to /xreactor/config/fuel_routes.lua
--   [Reset]     clears all routes
--
-- Config is loaded from and saved to disk so it survives reboots.
-- The redstone_router is updated immediately on save.

local M = {}

local ROUTE_CONFIG_PATH = "/xreactor/config/fuel_routes.lua"

local BUILTIN_SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- ---- disk persistence ------------------------------------------------------

local function load_routes()
  if not fs.exists(ROUTE_CONFIG_PATH) then return {} end
  local ok, result = pcall(dofile, ROUTE_CONFIG_PATH)
  if ok and type(result) == "table" then return result end
  return {}
end

local function save_routes(routes)
  local dir = fs.getDir(ROUTE_CONFIG_PATH)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(ROUTE_CONFIG_PATH, "w")
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

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    redstone_router = opts.redstone_router,  -- redstone_router instance to update on save
    log             = opts.log or function() end,
    get_reactors    = opts.get_reactors or function() return {} end,
    _ui = {
      selected_side = nil,
      selected_int  = nil,
      routes        = {},      -- { side, integrator, reactor, label }
      dirty         = false,
      side_btns     = {},
      reactor_btns  = {},
      save_btn      = nil,
      reset_btn     = nil,
    },
  }
  -- Load persisted routes on startup
  self._ui.routes = load_routes()
  return setmetatable(self, { __index = M })
end

-- ---- route helpers ---------------------------------------------------------

function M:_find(side, integrator)
  for _, r in ipairs(self._ui.routes) do
    if r.side == side and (r.integrator or nil) == (integrator or nil) then
      return r
    end
  end
  return nil
end

function M:_remove(side, integrator)
  local new = {}
  for _, r in ipairs(self._ui.routes) do
    if not (r.side == side and (r.integrator or nil) == (integrator or nil)) then
      new[#new + 1] = r
    end
  end
  self._ui.routes = new
  self._ui.dirty  = true
end

function M:_assign(side, integrator, reactor_id, label)
  self:_remove(side, integrator)
  self._ui.routes[#self._ui.routes + 1] = {
    side       = side,
    integrator = integrator or nil,
    reactor    = reactor_id,
    label      = label,
  }
  self._ui.dirty = true
end

-- ---- render ----------------------------------------------------------------

function M:render(target, ui, colors)
  local w, h = ui.getSize(target)
  if not w or not h then return end

  local u = self._ui
  local col_w = math.floor((w - 3) / 2)
  local mid   = col_w + 3

  -- Background
  target.setBackgroundColor(colors.get("background"))
  target.clear()

  -- Panel
  ui.panel(target, 1, 1, w, h, "Fuel-Router Konfiguration", "OK")

  -- Headers
  target.setCursorPos(2, 2)
  target.setTextColor(colors.get("text"))
  target.setBackgroundColor(colors.get("panel"))
  target.write("Redstone-Ausgaben")

  target.setCursorPos(mid, 2)
  target.setTextColor(colors.get("success") or colors.cyan)
  target.write("Reaktoren")

  -- Divider
  for row = 3, h - 3 do
    target.setCursorPos(mid - 1, row)
    target.setBackgroundColor(colors.get("background"))
    target.setTextColor(colors.get("disabled") or colors.gray)
    target.write("|")
  end

  -- Left column: sides
  local side_btns = {}
  local reactors = self.get_reactors()

  for i, side in ipairs(BUILTIN_SIDES) do
    local row = i + 2
    if row > h - 3 then break end
    local assigned = self:_find(side, nil)
    local is_sel   = u.selected_side == side and u.selected_int == nil

    local bg = is_sel   and colors.yellow
             or assigned and colors.green
             or             colors.get("background")
    local fg = (bg ~= colors.get("background")) and colors.black
             or colors.get("text")

    local label = side
    if assigned then
      label = side .. " → " .. (assigned.label or assigned.reactor or "?"):sub(1, col_w - 6)
    end

    target.setCursorPos(2, row)
    target.setBackgroundColor(bg)
    target.setTextColor(fg)
    target.write((" " .. label .. string.rep(" ", col_w)):sub(1, col_w))
    target.setBackgroundColor(colors.get("background"))

    side_btns[#side_btns + 1] = {
      x1 = 2, x2 = 2 + col_w, y = row,
      side = side, integrator = nil,
    }
  end
  u.side_btns = side_btns

  -- Right column: reactors
  local rx_btns = {}
  for i, rx in ipairs(reactors) do
    local row = i + 2
    if row > h - 3 then break end
    local is_assigned = false
    for _, r in ipairs(u.routes) do
      if r.reactor == rx.id then is_assigned = true; break end
    end

    local bg = is_assigned and colors.green or colors.get("background")
    local fg = is_assigned and colors.black  or (colors.get("success") or colors.cyan)

    target.setCursorPos(mid, row)
    target.setBackgroundColor(bg)
    target.setTextColor(fg)
    target.write((" " .. (rx.label or rx.id) .. string.rep(" ", col_w)):sub(1, col_w))
    target.setBackgroundColor(colors.get("background"))

    rx_btns[#rx_btns + 1] = {
      x1 = mid, x2 = mid + col_w, y = row,
      id = rx.id, label = rx.label or rx.id,
    }
  end
  u.reactor_btns = rx_btns

  -- Hint line
  local hint = u.selected_side
    and ("Ausgang '" .. u.selected_side .. "' gewählt → Reaktor antippen zum Zuweisen")
    or  "Linke Spalte antippen um Ausgang zu wählen"
  target.setCursorPos(2, h - 2)
  target.setBackgroundColor(colors.get("background"))
  target.setTextColor(colors.get("disabled") or colors.gray)
  target.write(hint:sub(1, w - 2))

  -- Buttons row
  local btn_y = h - 1
  local save_lbl = u.dirty and "[* Speichern ]" or "[ Speichern  ]"
  target.setCursorPos(2, btn_y)
  target.setBackgroundColor(u.dirty and colors.orange or colors.gray)
  target.setTextColor(colors.white)
  target.write(save_lbl)
  target.setBackgroundColor(colors.get("background"))
  u.save_btn = { x1 = 2, x2 = 2 + #save_lbl - 1, y = btn_y }

  local reset_lbl = "[ Reset ]"
  local rx_start = w - #reset_lbl
  target.setCursorPos(rx_start, btn_y)
  target.setBackgroundColor(colors.red)
  target.setTextColor(colors.white)
  target.write(reset_lbl)
  target.setBackgroundColor(colors.get("background"))
  u.reset_btn = { x1 = rx_start, x2 = w, y = btn_y }

  -- Route count
  local count_lbl = #u.routes .. " Routen" .. (u.dirty and " (ungespeichert)" or "")
  local count_x = math.floor((w - #count_lbl) / 2)
  target.setCursorPos(count_x, btn_y)
  target.setBackgroundColor(colors.get("background"))
  target.setTextColor(u.dirty and colors.orange or colors.get("text"))
  target.write(count_lbl)
end

-- ---- touch input -----------------------------------------------------------

function M:handle_touch(x, y)
  local u = self._ui

  -- Save button
  local sb = u.save_btn
  if sb and y == sb.y and x >= sb.x1 and x <= sb.x2 then
    self:_do_save()
    return true
  end

  -- Reset button
  local rb = u.reset_btn
  if rb and y == rb.y and x >= rb.x1 and x <= rb.x2 then
    u.routes = {}
    u.selected_side = nil
    u.dirty = true
    return true
  end

  -- Side buttons
  for _, btn in ipairs(u.side_btns) do
    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
      if u.selected_side == btn.side and u.selected_int == btn.integrator then
        -- Second tap: deselect (or remove if assigned)
        self:_remove(btn.side, btn.integrator)
        u.selected_side = nil
        u.selected_int  = nil
      else
        u.selected_side = btn.side
        u.selected_int  = btn.integrator
      end
      return true
    end
  end

  -- Reactor buttons (only if a side is selected)
  if u.selected_side then
    for _, btn in ipairs(u.reactor_btns) do
      if y == btn.y and x >= btn.x1 and x <= btn.x2 then
        self:_assign(u.selected_side, u.selected_int, btn.id, btn.label)
        u.selected_side = nil
        u.selected_int  = nil
        return true
      end
    end
  end

  return false
end

-- ---- save ------------------------------------------------------------------

function M:_do_save()
  local u = self._ui
  local ok = save_routes(u.routes)
  if ok then
    self.log("INFO", "RouterUI: saved " .. #u.routes .. " routes to " .. ROUTE_CONFIG_PATH)
    u.dirty = false
    -- Apply immediately to redstone_router
    if self.redstone_router then
      -- Push routes into config and refresh
      local cfg = self.redstone_router.config
      local lg = cfg.logistics or cfg
      lg.redstone_routes = {}
      for _, r in ipairs(u.routes) do
        lg.redstone_routes[#lg.redstone_routes + 1] = {
          reactor    = r.reactor,
          label      = r.label,
          side       = r.side,
          integrator = r.integrator,
        }
      end
      self.redstone_router:refresh()
      self.log("INFO", "RouterUI: redstone_router updated with " .. #u.routes .. " routes")
    end
  else
    self.log("WARN", "RouterUI: failed to save routes to " .. ROUTE_CONFIG_PATH)
  end
end

-- ---- public: get current routes --------------------------------------------

function M:get_routes()
  return self._ui.routes
end

return M
