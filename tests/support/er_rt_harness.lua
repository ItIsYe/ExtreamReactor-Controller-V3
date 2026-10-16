-- tests/support/er_rt_harness.lua
--
-- Faehrt den ECHTEN RT-Stapel (rt2_engine -> rt2_orchestrator ->
-- rt2_turbine/rt2_reactor, ueber adapters/turbine.lua und
-- adapters/reactor.lua) gegen das Anlagenmodell aus
-- tests/support/er_plant_model.lua.
--
-- Die CC:Tweaked-Umgebung wird hier EINMAL aufgebaut, damit die
-- eigentlichen Testdateien nur noch das Szenario beschreiben. Die
-- Peripherie-Schicht benutzt die echten Methodennamen und die echte
-- Bedeutung aus TurbineComputerPeripheral.java:
--
--   getFluidFlowRateMax     -> getMaxIntakeRate()        (der SOLLWERT)
--   setFluidFlowRateMax     -> setMaxIntakeRate()        (klemmt auf die Variante)
--   getFluidFlowRateMaxMax  -> getMaxIntakeRateHardLimit (1000 / 2000)
--   getFluidFlowRate        -> getFluidConsumedLastTick  (der VERBRAUCH)

local ER = require('support.er_plant_model')

local M = {}

local TURBINE_METHODS = {
  'getActive', 'setActive', 'getRotorSpeed', 'getRotorMass', 'getNumberOfBlades',
  'getFluidFlowRate', 'getFluidFlowRateMax', 'setFluidFlowRateMax', 'getFluidFlowRateMaxMax',
  'getEnergyProducedLastTick', 'getEnergyStored', 'getEnergyCapacity',
  'getInductorEngaged', 'setInductorEngaged', 'getInputAmount', 'getFluidAmountMax',
}
local REACTOR_METHODS = {
  'getActive', 'setActive', 'getFuelTemperature', 'getCasingTemperature', 'getEnergyStored',
  'getEnergyProducedLastTick', 'getFuelAmount', 'getWasteAmount', 'getFuelAmountMax',
  'getControlRodLevel', 'setAllControlRodLevels', 'getNumberOfControlRods',
  'getHotFluidAmount', 'getHotFluidAmountMax', 'isActivelyCooled',
  'getCoolantAmount', 'getCoolantAmountMax',
}

local function install_cc_environment()
  local files = { ['/xreactor_config'] = '<dir>' }
  _G.fs = {
    exists = function(p) return files[p] ~= nil end,
    getDir = function() return '/xreactor_config' end,
    makeDir = function(p) files[p] = '<dir>' end,
    delete = function(p) files[p] = nil end,
    move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
    open = function(p, mode)
      if mode == 'w' then
        local buffer = ''
        return { write = function(v) buffer = buffer .. tostring(v) end,
                 close = function() files[p] = buffer end }
      elseif mode == 'r' then
        if files[p] == nil or files[p] == '<dir>' then return nil end
        return { readAll = function() return files[p] end, close = function() end }
      end
      return nil
    end,
  }
  _G.textutils = {
    serialize = function(value)
      local function encode(v)
        if type(v) == 'string' then return string.format('%q', v) end
        if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
        if type(v) ~= 'table' then return 'nil' end
        local parts = {}
        for k, item in pairs(v) do parts[#parts + 1] = '[' .. encode(k) .. ']=' .. encode(item) end
        table.sort(parts)
        return '{' .. table.concat(parts, ',') .. '}'
      end
      return encode(value)
    end,
    unserialize = function(content)
      local loader = load('return ' .. content, '=cache', 't', {})
      if not loader then return nil end
      local ok, value = pcall(loader)
      return ok and value or nil
    end,
  }
  _G.settings = { get = function() return false end }
end

-- opts = {
--   turbine_count, turbine (Bauform fuer M.new_turbine),
--   reactor_headroom (Faktor auf den nach ROD_MIN nutzbaren Anteil),
--   steam_capacity,
-- }
function M.new(opts)
  opts = opts or {}
  install_cc_environment()

  local turbine_spec = opts.turbine or {
    variant = 'reinforced', blades = 80, shaft_blocks = 20,
    coil_blocks = 74, coil = 'enderium',
  }
  local count = opts.turbine_count or 6
  local per_turbine_flow = ER.VARIANTS[turbine_spec.variant or 'reinforced'].max_permitted_flow
  local fleet_demand = count * per_turbine_flow

  -- Reaktorgroesse nach dem BETRIEBSFENSTER des Reglers, nicht nach dem
  -- Nennwert: rt2_reactor.ROD_MIN = 70 ist eine bewusste Leistungsgrenze
  -- (Betreibervorgabe) -- die Staebe fahren nie weiter als bis 70 %
  -- Einschub aus, und Extreme Reactors senkt die Strahlung proportional
  -- zum Einschub. Nutzbar sind also rund 30 % des Nennwerts.
  local headroom = opts.reactor_headroom or 1.15
  local self = {
    plant = ER.new_plant({
      reactor = ER.new_reactor({
        max_steam_per_tick = math.floor(fleet_demand / 0.30 * headroom),
        steam_capacity = opts.steam_capacity or 200000,
      }),
    }),
    turbine_names = {},
    reactor_name = 'reactor_0',
    clock_ms = 1000000,
    logged = {},
  }

  for i = 1, count do
    local name = string.format('turbine_%d', i)
    self.turbine_names[#self.turbine_names + 1] = name
    self.plant.turbines[name] = ER.new_turbine(turbine_spec)
  end

  local plant = self.plant
  local reactor_name = self.reactor_name

  _G.peripheral = {
    isPresent = function(name) return plant.turbines[name] ~= nil or name == reactor_name end,
    getType = function(name)
      return plant.turbines[name] and 'BigReactors-Turbine' or 'BigReactors-Reactor'
    end,
    getMethods = function(name)
      return plant.turbines[name] and TURBINE_METHODS or REACTOR_METHODS
    end,
    call = function(name, method, ...)
      local t = plant.turbines[name]
      if t then
        if method == 'getActive' then return t.active end
        if method == 'setActive' then t.active = (...) and true or false; return true end
        if method == 'getRotorSpeed' then return t:rotor_speed() end
        if method == 'getRotorMass' then return t.rotor_mass end
        if method == 'getNumberOfBlades' then return t.blades end
        if method == 'getFluidFlowRate' then return t.fluid_consumed_last_tick end
        if method == 'getFluidFlowRateMax' then return t.max_intake_rate end
        if method == 'getFluidFlowRateMaxMax' then return t.variant.max_permitted_flow end
        if method == 'setFluidFlowRateMax' then t:set_max_intake_rate((...)); return true end
        if method == 'getEnergyProducedLastTick' then return t.energy_generated_last_tick end
        if method == 'getEnergyStored' then return 0 end
        if method == 'getEnergyCapacity' then return 20000 end
        if method == 'getInductorEngaged' then return t.inductor_engaged end
        if method == 'setInductorEngaged' then t.inductor_engaged = (...) and true or false; return true end
        if method == 'getInputAmount' then return t.vapor_amount end
        if method == 'getFluidAmountMax' then return t.vapor_capacity end
        error('unerwartete Turbinen-Methode ' .. tostring(method), 0)
      end
      if name ~= reactor_name then error('unbekannte Peripherie ' .. tostring(name), 0) end
      local r = plant.reactor
      if method == 'getActive' then return r.active end
      if method == 'setActive' then r.active = (...) and true or false; return true end
      if method == 'getFuelTemperature' then return r.fuel_temperature end
      if method == 'getCasingTemperature' then return r.fuel_temperature * 0.8 end
      if method == 'getCoolantAmount' then return r.coolant end
      if method == 'getCoolantAmountMax' then return r.coolant_capacity end
      if method == 'getEnergyStored' then return 0 end
      if method == 'getEnergyProducedLastTick' then return 0 end
      if method == 'getFuelAmount' then return r.fuel end
      if method == 'getWasteAmount' then return r.waste end
      if method == 'getFuelAmountMax' then return r.fuel_capacity end
      if method == 'getControlRodLevel' then return r.rods end
      if method == 'getNumberOfControlRods' then return 1 end
      if method == 'setAllControlRodLevels' then r.rods = tonumber((...)) or r.rods; return true end
      if method == 'getHotFluidAmount' then return r.steam end
      if method == 'getHotFluidAmountMax' then return r.steam_capacity end
      if method == 'isActivelyCooled' then return true end
      error('unerwartete Reaktor-Methode ' .. tostring(method), 0)
    end,
    wrap = function(name)
      return setmetatable({}, { __index = function(_, method)
        return function(...) return _G.peripheral.call(name, method, ...) end
      end })
    end,
  }

  os.epoch = function() return self.clock_ms end

  local config = { reactors = { reactor_name }, turbines = self.turbine_names }
  local modules_registry = {}
  for _, name in ipairs(self.turbine_names) do
    modules_registry['turbine:' .. name] =
      { id = 'turbine:' .. name, type = 'turbine', name = name, state = 'OFF', progress = 0 }
  end
  modules_registry['reactor:' .. reactor_name] =
    { id = 'reactor:' .. reactor_name, type = 'reactor', name = reactor_name,
      state = 'OFF', progress = 0 }

  self.config = config
  self.ctx = {
    config = config,
    CONFIG = { LOG_PREFIX = 'RT' },
    adapters = { reactor = require('adapters.reactor'), turbine = require('adapters.turbine') },
    modules = modules_registry,
    log = function(level, msg) self.logged[#self.logged + 1] = tostring(level) .. ' ' .. tostring(msg) end,
  }

  self.engine = require('nodes.rt.rt2_engine')
  self.engine.init({ log = self.ctx.log, config = config })
  return setmetatable(self, { __index = M })
end

-- Ein Reglertakt (100 ms, nodes/rt/main.lua's RECEIVE_TIMEOUT) plus die
-- zwei Minecraft-Ticks (je 50 ms), die in dieser Zeit vergehen.
function M:step(before_tick)
  if before_tick then before_tick(self) end
  local ok, result = pcall(self.engine.tick, self.ctx)
  if not ok then
    error(string.format('Reglertakt bei t=%.1fs ist gescheitert: %s',
      (self.clock_ms - 1000000) / 1000, tostring(result)), 0)
  end
  self.last = result
  self.plant:tick()
  self.plant:tick()
  self.clock_ms = self.clock_ms + 100
  return result
end

function M:run(seconds, before_tick)
  for _ = 1, math.floor(seconds * 10) do self:step(before_tick) end
  return self.last
end

function M:count_log(pattern)
  local n = 0
  for _, line in ipairs(self.logged) do
    if line:find(pattern, 1, true) then n = n + 1 end
  end
  return n
end

function M:describe()
  local parts = {}
  for _, n in ipairs(self.turbine_names) do
    local t = self.plant.turbines[n]
    parts[#parts + 1] = string.format('%s rpm=%.1f flow=%d coil=%s FE/t=%.0f',
      n, t:rotor_speed(), t.max_intake_rate, tostring(t.inductor_engaged),
      t.energy_generated_last_tick)
  end
  return table.concat(parts, ' | ')
end

return M
