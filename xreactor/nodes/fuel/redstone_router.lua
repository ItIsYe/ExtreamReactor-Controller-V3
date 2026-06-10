-- nodes/fuel/redstone_router.lua
--
-- Controls redstone outputs to route Mekanism pipe traffic to specific reactors.
--
-- Mekanism Logistical Transporters configured as "High = Interrupt":
--   redstone HIGH  → pipe BLOCKED at that segment
--   redstone LOW   → pipe OPEN (default)
--
-- Routing strategy: block ALL reactor pipes, then open ONLY the target.
-- This ensures items only flow to the reactor that requested fuel.
--
-- Hardware options:
--   A) CC computer built-in redstone (6 sides: top/bottom/left/right/front/back)
--   B) Redstone Integrator peripheral (16 named outputs, more reactors)
--   C) Both combined
--
-- Route table (config.logistics.redstone_routes):
--   { reactor = "RT-1", label = "Reaktor A",
--     side    = "right",       -- built-in side OR integrator output name
--     integrator = nil         -- optional: "redstone_integrator_0"
--   }
--
-- Timing (config.logistics.valve_open_ms):
--   How long to keep the target pipe open after exporting. Default 2000ms.
--   Mekanism moves items in ~2-4 ticks (100-200ms) but give headroom.

local M = {}

local BUILTIN_SIDES = {
  top=true, bottom=true, left=true, right=true, front=true, back=true
}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil, "no_method" end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state = {
      routes      = {},  -- compiled route table: { label, side, integrator, wrapped }
      all_blocked = false,
      integrators = {},  -- wrapped Redstone Integrator peripherals by name
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery --------------------------------------------------

function M:refresh()
  local cfg = self.config.logistics or self.config or {}
  local routes_cfg = cfg.redstone_routes or {}

  -- Collect unique integrator names
  local integrator_names = {}
  for _, r in ipairs(routes_cfg) do
    if r.integrator then integrator_names[r.integrator] = true end
  end

  -- Wrap integrators
  local integrators = {}
  for name in pairs(integrator_names) do
    if peripheral.isPresent(name) then
      local ok, w = pcall(peripheral.wrap, name)
      if ok and w then
        integrators[name] = w
        self.log("DEBUG", "RedstoneRouter: integrator " .. name .. " connected")
      else
        self.warn_once("int_wrap:" .. name, "RedstoneRouter: wrap failed: " .. name)
      end
    else
      self.warn_once("int_absent:" .. name, "RedstoneRouter: integrator absent: " .. name)
    end
  end
  self._state.integrators = integrators

  -- Compile route table
  local routes = {}
  for i, r in ipairs(routes_cfg) do
    if not r.side then
      self.warn_once("route_no_side_" .. i, "RedstoneRouter: route " .. i .. " missing side")
    else
      local integrator = r.integrator and integrators[r.integrator] or nil
      routes[#routes + 1] = {
        label      = r.label or r.reactor or ("Route " .. i),
        reactor_id = r.reactor,
        side       = r.side,
        integrator = integrator,
        int_name   = r.integrator,
      }
    end
  end
  self._state.routes = routes

  -- Start with all routes blocked (safe default)
  self:block_all()

  self.log("DEBUG", "RedstoneRouter: " .. #routes .. " routes loaded")
end

-- ---- redstone primitives ---------------------------------------------------

-- Set output for one route entry.
-- high=true: pipe BLOCKED; high=false: pipe OPEN
function M:_set_output(route, high)
  local side = route.side
  if route.integrator then
    -- Redstone Integrator: setOutput(side, bool)
    local _, err = safe_call(route.integrator, "setOutput", side, high)
    if err then
      self.warn_once("rs_set:" .. route.label,
        "RedstoneRouter: setOutput failed for " .. route.label .. ": " .. tostring(err))
    end
  elseif BUILTIN_SIDES[side] then
    -- Built-in computer redstone
    pcall(redstone.setOutput, side, high)
  else
    self.warn_once("rs_side:" .. side,
      "RedstoneRouter: unknown side '" .. side .. "' (not builtin, no integrator)")
  end
end

-- Block all routes (safe default — no fuel flows anywhere).
function M:block_all()
  for _, route in ipairs(self._state.routes) do
    self:_set_output(route, true)  -- HIGH = blocked
  end
  self._state.all_blocked = true
  self.log("DEBUG", "RedstoneRouter: all routes blocked")
end

-- Open exactly ONE route (target), block all others.
-- Returns true if the target route was found.
function M:open_only(reactor_id_or_label)
  local found = false
  for _, route in ipairs(self._state.routes) do
    local match = (route.reactor_id == reactor_id_or_label)
               or (route.label      == reactor_id_or_label)
    if match then
      self:_set_output(route, false)  -- LOW = open
      found = true
      self.log("DEBUG", "RedstoneRouter: opened route to " .. route.label)
    else
      self:_set_output(route, true)   -- HIGH = blocked
    end
  end
  if not found then
    self.log("WARN", "RedstoneRouter: no route found for " .. tostring(reactor_id_or_label))
  end
  self._state.all_blocked = not found
  return found
end

-- ---- timed routing sequence ------------------------------------------------

-- Open route for target, call action_fn(), then block all again.
-- valve_open_ms: how long to keep valve open AFTER action (default 2000ms).
function M:route_and_act(reactor_id, action_fn, valve_open_ms)
  if #self._state.routes == 0 then
    -- No routes configured: act directly without redstone control
    if action_fn then action_fn() end
    return
  end

  local opened = self:open_only(reactor_id)
  if not opened then
    self.log("WARN", "RedstoneRouter: could not open route for " .. tostring(reactor_id))
    self:block_all()
    return
  end

  -- Small settle time before pushing items (1 tick ≈ 50ms)
  os.sleep(0.05)

  if action_fn then action_fn() end

  -- Keep valve open for Mekanism to move items
  local hold_ms = tonumber(valve_open_ms) or 2000
  os.sleep(hold_ms / 1000)

  self:block_all()
end

-- ---- status ----------------------------------------------------------------

function M:get_routes()
  local result = {}
  for _, r in ipairs(self._state.routes) do
    result[#result + 1] = {
      label      = r.label,
      reactor_id = r.reactor_id,
      side       = r.side,
      integrator = r.int_name,
    }
  end
  return result
end

function M:route_count()
  return #self._state.routes
end

return M
