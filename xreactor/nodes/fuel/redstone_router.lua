-- nodes/fuel/redstone_router.lua
--
-- Tree-topology redstone valve routing for Mekanism pipe networks.
--
-- Physical topology example:
--
--   Haupt-Pipe
--     ├── [Ventil side="right"] Rechter Arm
--     │       ├── [Ventil side="top"]    Reaktor A  (reactor="RT-1")
--     │       └── [Ventil side="bottom"] Reaktor B  (reactor="RT-2")
--     └── [Ventil side="left"]  Linker Arm
--             ├── [Ventil side="front"]  Reaktor C  (reactor="RT-3")
--             └── [Ventil side="back"]   Reaktor D  (reactor="RT-4")
--
-- Routing to Reaktor A:
--   Open:  right, top
--   Block: left, bottom, front, back
--
-- Mekanism pipe mode: High Redstone = Interrupt
--   HIGH output → pipe BLOCKED
--   LOW  output → pipe OPEN (default)
--
-- Config (config.logistics.redstone_tree): recursive node tree.

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

local function collect_all_valves(tree, out)
  out = out or {}
  for _, node in ipairs(tree or {}) do
    if node.side then out[#out + 1] = { side = node.side, integrator = node.integrator } end
    collect_all_valves(node.children or {}, out)
  end
  return out
end

local function find_path(tree, target_id, path)
  path = path or {}
  for _, node in ipairs(tree or {}) do
    local valve = node.side and { side = node.side, integrator = node.integrator } or nil
    local next_path = valve and (function()
      local p = {}
      for _, v in ipairs(path) do p[#p + 1] = v end
      p[#p + 1] = valve
      return p
    end)() or path
    if node.reactor == target_id or node.label == target_id then return next_path end
    local found = find_path(node.children or {}, target_id, next_path)
    if found then return found end
  end
  return nil
end

function M.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config or {},
    log = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state = { all_valves = {}, integrators = {} },
  }
  return setmetatable(self, { __index = M })
end

function M:refresh()
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  local all = collect_all_valves(tree)
  self._state.all_valves = all

  local int_names = {}
  for _, v in ipairs(all) do if v.integrator then int_names[v.integrator] = true end end
  local integrators = {}
  for name in pairs(int_names) do
    if peripheral.isPresent(name) then
      local ok, w = pcall(peripheral.wrap, name)
      if ok and w then
        integrators[name] = w
        self.log("DEBUG", "RedstoneRouter: integrator " .. name)
      else
        self.warn_once("int:" .. name, "RedstoneRouter: integrator wrap failed: " .. name)
      end
    else
      self.warn_once("int_abs:" .. name, "RedstoneRouter: integrator absent: " .. name)
    end
  end
  self._state.integrators = integrators
  self:block_all()
  self.log("DEBUG", string.format("RedstoneRouter: tree loaded, %d total valves", #all))
end

function M:_set_valve(valve, high)
  local side = valve.side
  if valve.integrator then
    local w = self._state.integrators[valve.integrator]
    if w then safe_call(w, "setOutput", side, high) end
  elseif BUILTIN_SIDES[side] then
    pcall(redstone.setOutput, side, high)
  else
    self.warn_once("bad_side:" .. tostring(side), "RedstoneRouter: unknown side '" .. tostring(side) .. "'")
  end
end

function M:block_all()
  for _, v in ipairs(self._state.all_valves) do self:_set_valve(v, true) end
end

function M:open_path_to(target_id)
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  local path = find_path(tree, target_id)
  if not path then
    self.log("WARN", "RedstoneRouter: no path found for target: " .. tostring(target_id))
    self:block_all()
    return false
  end

  local path_set = {}
  for _, v in ipairs(path) do path_set[(v.integrator or "") .. ":" .. v.side] = true end
  for _, v in ipairs(self._state.all_valves) do
    local key = (v.integrator or "") .. ":" .. v.side
    self:_set_valve(v, not path_set[key])
  end

  local sides = {}
  for _, v in ipairs(path) do sides[#sides + 1] = v.side end
  self.log("DEBUG", string.format("RedstoneRouter: routing to %s via [%s]", tostring(target_id), table.concat(sides, " → ")))
  return true
end

function M:route_and_act(target_id, action_fn, valve_open_ms)
  if #self._state.all_valves == 0 then
    if action_fn then action_fn() end
    return
  end
  local ok = self:open_path_to(target_id)
  if not ok then
    self.log("WARN", "RedstoneRouter: cannot route to " .. tostring(target_id))
    self:block_all()
    return
  end
  os.sleep(0.05)
  if action_fn then action_fn() end
  os.sleep((tonumber(valve_open_ms) or 2000) / 1000)
  self:block_all()
end

function M:valve_count()
  return #self._state.all_valves
end

-- Compatibility/introspection: logistics_router already treats this as the number
-- of configured reactor routes. Keep it separate from valve_count(), because a
-- single reactor path can contain multiple valves.
function M:route_count()
  return #self:get_routing_table()
end

-- Expose the configured recursive topology read-only by convention for UI use.
function M:get_tree()
  local cfg = self.config.logistics or self.config or {}
  return cfg.redstone_tree or {}
end

function M:get_path_to(target_id)
  local cfg = self.config.logistics or self.config or {}
  local path = find_path(cfg.redstone_tree or {}, target_id) or {}
  local sides = {}
  for _, v in ipairs(path) do sides[#sides + 1] = v.side end
  return sides
end

function M:get_routing_table()
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  local result = {}
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      if node.reactor then
        local path = find_path(tree, node.reactor) or {}
        local sides = {}
        for _, v in ipairs(path) do sides[#sides + 1] = v.side end
        result[#result + 1] = {
          reactor = node.reactor,
          label = node.label or node.reactor,
          path = sides,
        }
      end
      walk(node.children or {})
    end
  end
  walk(tree)
  return result
end

return M
