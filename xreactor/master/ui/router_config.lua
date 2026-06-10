-- master/ui/router_config.lua
--
-- Touch-based routing configuration panel for the FUEL node's redstone router.
--
-- Layout:
--   Left column:  Redstone outputs (sides + integrator channels)
--   Right column: Registered reactors/fuel nodes
--   Center:       Current assignments with connection lines
--
-- Interaction:
--   1. Tap a redstone output → it is SELECTED (highlighted)
--   2. Tap a reactor         → the selected output is ASSIGNED to this reactor
--   3. Tap an assigned line  → remove the assignment
--   4. [Save] button         → send SET_FUEL_ROUTES to the FUEL node via comms

local M = {}
local widgets = require("master.ui.widgets")
local ui      = require("core.ui")
local colors_lib = require("shared.colors")

local COL = {
  SELECTED  = colors.yellow,
  ASSIGNED  = colors.green,
  UNASSIGNED= colors.lightGray,
  REACTOR   = colors.cyan,
  HEADER    = colors.white,
  BG        = colors.black,
  BUTTON_OK = colors.green,
  BUTTON_DEL= colors.red,
}

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    model       = opts.model or {},   -- from ui_controller: nodes, fuel_node status
    send_cmd    = opts.send_cmd,      -- function(node_id, cmd, payload)
    log         = opts.log or function() end,
    _state = {
      selected_side   = nil,   -- currently selected redstone output (string)
      routes          = {},    -- current assignments: { side = "right", reactor_id = "RT-1", label = "Reaktor A" }
      dirty           = false, -- unsaved changes
      sides_list      = {},    -- rendered side buttons with hit areas
      reactors_list   = {},    -- rendered reactor buttons with hit areas
      save_btn        = nil,   -- save button hit area
      clear_btn       = nil,   -- clear all button
      fuel_node_id    = nil,   -- which FUEL node to configure
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- Available redstone outputs --------------------------------------------

-- Returns list of { label, side_key } for built-in sides.
local BUILTIN_SIDES = {
  { label = "Oben    (top)",    side = "top"    },
  { label = "Unten   (bottom)", side = "bottom" },
  { label = "Links   (left)",   side = "left"   },
  { label = "Rechts  (right)",  side = "right"  },
  { label = "Vorne   (front)",  side = "front"  },
  { label = "Hinten  (back)",   side = "back"   },
}

-- Build side list: built-in + integrator channels if configured.
function M:_build_sides_list(routes)
  local sides = {}
  for _, s in ipairs(BUILTIN_SIDES) do
    sides[#sides + 1] = { label = s.label, side = s.side, integrator = nil }
  end
  -- Add any integrator channels already in routes
  local seen = {}
  for _, r in ipairs(routes or {}) do
    if r.integrator and not seen[r.integrator .. ":" .. (r.side or "")] then
      seen[r.integrator .. ":" .. r.side] = true
      sides[#sides + 1] = {
        label = string.format("Int[%s]/%s", r.integrator, r.side),
        side  = r.side,
        integrator = r.integrator,
      }
    end
  end
  return sides
end

-- ---- Find assignment for a side -------------------------------------------

function M:_find_route(side, integrator)
  for _, r in ipairs(self._state.routes) do
    if r.side == side and (r.integrator or nil) == (integrator or nil) then
      return r
    end
  end
  return nil
end

function M:_remove_route(side, integrator)
  local new = {}
  for _, r in ipairs(self._state.routes) do
    if not (r.side == side and (r.integrator or nil) == (integrator or nil)) then
      new[#new + 1] = r
    end
  end
  self._state.routes = new
  self._state.dirty = true
end

function M:_assign(side, integrator, reactor_id, label)
  self:_remove_route(side, integrator)
  self._state.routes[#self._state.routes + 1] = {
    side       = side,
    integrator = integrator,
    reactor    = reactor_id,
    label      = label,
  }
  self._state.dirty = true
end

-- ---- Collect reactor list from model --------------------------------------

function M:_get_reactors()
  local reactors = {}
  local nodes = (self.model and self.model.nodes) or {}
  for _, node in ipairs(nodes) do
    local role = tostring(node.role or ""):upper()
    if role == "RT" or role == "REACTOR" then
      reactors[#reactors + 1] = {
        id    = node.id,
        label = node.id,
        status = node.status or "OFFLINE",
      }
    end
  end
  -- Also add manually configured entries from existing routes
  for _, r in ipairs(self._state.routes) do
    local found = false
    for _, rx in ipairs(reactors) do
      if rx.id == r.reactor then found = true; break end
    end
    if not found and r.reactor then
      reactors[#reactors + 1] = { id = r.reactor, label = r.label or r.reactor, status = "?" }
    end
  end
  return reactors
end

-- ---- Draw ------------------------------------------------------------------

function M:draw(mon, x, y, w, h)
  local s = self._state
  if not s.fuel_node_id then
    -- Find FUEL node from model
    local nodes = (self.model and self.model.nodes) or {}
    for _, n in ipairs(nodes) do
      if tostring(n.role or ""):upper() == "FUEL" then
        s.fuel_node_id = n.id
        break
      end
    end
  end

  -- Sync sides list
  if #s.sides_list == 0 then
    s.sides_list = self:_build_sides_list(s.routes)
  end

  local mid = x + math.floor(w / 2)
  local col_w = math.floor(w / 2) - 1

  -- Clear area
  for row = y, y + h - 1 do
    mon.setCursorPos(x, row)
    mon.setBackgroundColor(COL.BG)
    mon.write(string.rep(" ", w))
  end

  -- Headers
  local function hdr(cx, cy, text, col)
    mon.setCursorPos(cx, cy)
    mon.setBackgroundColor(COL.BG)
    mon.setTextColor(col or COL.HEADER)
    mon.write(text:sub(1, col_w))
  end

  hdr(x,   y, "Redstone-Ausgänge",      COL.HEADER)
  hdr(mid, y, "Reaktoren",              COL.REACTOR)

  -- Draw divider
  for row = y + 1, y + h - 3 do
    mon.setCursorPos(mid - 1, row)
    mon.setBackgroundColor(COL.BG)
    mon.setTextColor(colors.gray)
    mon.write("|")
  end

  -- Left column: sides
  s.sides_list = self:_build_sides_list(s.routes)
  local side_btns = {}
  for i, side_entry in ipairs(s.sides_list) do
    local row = y + i
    if row >= y + h - 2 then break end
    local assigned = self:_find_route(side_entry.side, side_entry.integrator)
    local is_sel   = s.selected_side == side_entry.side
                  and (s.selected_integrator or nil) == (side_entry.integrator or nil)

    local bg = is_sel   and colors.yellow
             or assigned and colors.green
             or            COL.BG
    local fg = (bg == COL.BG) and COL.UNASSIGNED or colors.black

    mon.setCursorPos(x, row)
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    local label = side_entry.label:sub(1, col_w - 4)
    local arrow = assigned and (" →" .. (assigned.label or assigned.reactor or "?"):sub(1, 8)) or ""
    mon.write((" " .. label .. arrow):sub(1, col_w - 1))
    mon.setBackgroundColor(COL.BG)

    side_btns[#side_btns + 1] = {
      x1 = x, x2 = x + col_w - 2, y = row,
      side = side_entry.side, integrator = side_entry.integrator,
    }
  end
  s.sides_list = side_btns

  -- Right column: reactors
  local reactors = self:_get_reactors()
  local rx_btns = {}
  for i, rx in ipairs(reactors) do
    local row = y + i
    if row >= y + h - 2 then break end
    local is_assigned_here = false
    for _, r in ipairs(s.routes) do
      if r.reactor == rx.id then is_assigned_here = true; break end
    end
    local bg = is_assigned_here and colors.green or COL.BG
    local fg = is_assigned_here and colors.black  or COL.REACTOR
    mon.setCursorPos(mid, row)
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    mon.write((" " .. rx.label):sub(1, col_w))
    mon.setBackgroundColor(COL.BG)
    rx_btns[#rx_btns + 1] = {
      x1 = mid, x2 = mid + col_w, y = row,
      id = rx.id, label = rx.label,
    }
  end
  s.reactors_list = rx_btns

  -- Footer buttons
  local btn_y = y + h - 2
  -- [Speichern]
  local save_lbl = s.dirty and "[ Speichern* ]" or "[ Speichern  ]"
  mon.setCursorPos(x, btn_y)
  mon.setBackgroundColor(s.dirty and colors.orange or colors.gray)
  mon.setTextColor(colors.white)
  mon.write(save_lbl:sub(1, 15))
  mon.setBackgroundColor(COL.BG)
  s.save_btn = { x1 = x, x2 = x + 14, y = btn_y }

  -- [Alle löschen]
  mon.setCursorPos(x + 17, btn_y)
  mon.setBackgroundColor(colors.red)
  mon.setTextColor(colors.white)
  mon.write("[ Alle löschen ]")
  mon.setBackgroundColor(COL.BG)
  s.clear_btn = { x1 = x + 17, x2 = x + 32, y = btn_y }

  -- Status line
  local status = s.fuel_node_id
    and ("Konfiguriert für FUEL: " .. s.fuel_node_id)
    or  "Kein FUEL-Node verbunden"
  mon.setCursorPos(x, btn_y + 1)
  mon.setBackgroundColor(COL.BG)
  mon.setTextColor(s.fuel_node_id and colors.lightGray or colors.orange)
  mon.write(status:sub(1, w))
end

-- ---- Input handling --------------------------------------------------------

function M:handle_touch(x, y)
  local s = self._state

  -- Save button
  local sb = s.save_btn
  if sb and y == sb.y and x >= sb.x1 and x <= sb.x2 then
    self:_do_save()
    return true
  end

  -- Clear button
  local cb = s.clear_btn
  if cb and y == cb.y and x >= cb.x1 and x <= cb.x2 then
    s.routes = {}
    s.selected_side = nil
    s.dirty = true
    return true
  end

  -- Side buttons (left column)
  for _, btn in ipairs(s.sides_list) do
    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
      local already = self:_find_route(btn.side, btn.integrator)
      if already and s.selected_side == btn.side
         and (s.selected_integrator or nil) == (btn.integrator or nil) then
        -- Second tap on assigned/selected side → deselect or remove
        self:_remove_route(btn.side, btn.integrator)
        s.selected_side = nil
        s.selected_integrator = nil
      else
        -- Select this side
        s.selected_side        = btn.side
        s.selected_integrator  = btn.integrator
      end
      return true
    end
  end

  -- Reactor buttons (right column)
  if s.selected_side then
    for _, btn in ipairs(s.reactors_list) do
      if y == btn.y and x >= btn.x1 and x <= btn.x2 then
        self:_assign(s.selected_side, s.selected_integrator, btn.id, btn.label)
        s.selected_side       = nil
        s.selected_integrator = nil
        return true
      end
    end
  end

  return false
end

-- ---- Save (send to FUEL node) ----------------------------------------------

function M:_do_save()
  local s = self._state
  if not s.fuel_node_id then
    self.log("WARN", "RouterConfig: no FUEL node to save to")
    return
  end
  if self.send_cmd then
    self.send_cmd(s.fuel_node_id, "SET_FUEL_ROUTES", {
      routes = s.routes,
    })
    self.log("INFO", "RouterConfig: saved " .. #s.routes
      .. " routes to " .. s.fuel_node_id)
  end
  s.dirty = false
end

-- ---- Load routes from model (when FUEL node sends back current config) -----

function M:load_routes(routes)
  self._state.routes = routes or {}
  self._state.dirty  = false
end

-- ---- Page interface --------------------------------------------------------

function M.make_page(opts)
  local instance = M.new(opts)
  return {
    key      = "router",
    title    = "Fuel-Router",
    instance = instance,
    render   = function(mon, box, snapshot)
      instance.model = snapshot
      instance:draw(mon, box.x, box.y, box.w, box.h)
    end,
    handle_input = function(event)
      if event[1] == "monitor_touch" then
        return instance:handle_touch(event[3], event[4])
      end
      return false
    end,
  }
end

return M
