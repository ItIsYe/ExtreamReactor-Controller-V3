-- tests/support/plant_nodes.lua
--
-- Fertig verdrahtete Rollen fuer die Mehr-Knoten-Tests: eine Anlage, wie sie
-- im Spiel steht, als Bausteine. Damit beschreibt eine Testdatei nur noch das
-- SZENARIO und nicht jedes Mal 60 Zeilen Peripherie-Stubs.
--
-- Die Peripherie-Stubs benutzen die ECHTEN Methodennamen und die echte
-- Bedeutung aus Extreme Reactors 2.4.27 (siehe support/er_rt_harness.lua's
-- Kopf). Wer eine Methode weglassen will, um "dieses Geraet kennt das nicht"
-- zu beschreiben, uebergibt sie als nil in den opts.

local boot = require('support.cc_node_boot')

local M = {}

-- Ein Reaktor-Stub mit eigenem Zustand. Die Staebe sind SCHREIBBAR und werden
-- gelesen -- der Regler soll sie wirklich stellen koennen.
function M.new_reactor_stub(opts)
  opts = opts or {}
  local self = {
    rods = opts.rods or 100,
    rod_count = opts.rod_count or 1,
    steam = opts.steam or 14000,
    steam_max = opts.steam_max or 20000,
    fuel = opts.fuel or 3000,
    fuel_max = opts.fuel_max or 4000,
    temperature = opts.temperature or 900,
    coolant = opts.coolant or 9000,
    coolant_max = opts.coolant_max or 10000,
    active = opts.active ~= false,
    writes = 0,
  }
  self.methods = {
    getActive = function() return self.active end,
    setActive = function(v) self.active = v and true or false; return true end,
    getFuelTemperature = function() return self.temperature end,
    getCasingTemperature = function() return self.temperature * 0.8 end,
    getFuelAmount = function() return self.fuel end,
    getWasteAmount = function() return 10 end,
    getFuelAmountMax = function() return self.fuel_max end,
    getControlRodLevel = function() return self.rods end,
    setAllControlRodLevels = function(v)
      self.rods = tonumber(v) or self.rods
      self.writes = self.writes + 1
      return true
    end,
    getNumberOfControlRods = function() return self.rod_count end,
    getHotFluidAmount = function() return self.steam end,
    getHotFluidAmountMax = function() return self.steam_max end,
    isActivelyCooled = function() return true end,
    getCoolantAmount = function() return self.coolant end,
    getCoolantAmountMax = function() return self.coolant_max end,
    getEnergyStored = function() return 0 end,
    getEnergyProducedLastTick = function() return 0 end,
  }
  return self
end

-- Eine Turbine, deren Drehzahl AM DURCHFLUSS haengt.
--
-- Absichtlich nur eine Kennlinie, keine Physik -- diese Tests pruefen die
-- Naht zwischen den Rollen, nicht die Regelung; fuer die Regelung gibt es
-- support/er_plant_model.lua mit dem Modell aus dem Mod-Quelltext.
--
-- Eine KONSTANTE Drehzahl waere aber falsch, und zwar auf eine Weise, die
-- den Test luegen laesst: faehrt MASTER die Vorgabe zwischenzeitlich auf
-- 0 % (das tut er beim Start, solange keine Kapazitaet gemeldet ist), stellt
-- der Regler Durchfluss 0. Liest die Turbine danach WEITER 900 RPM, gilt sie
-- als "am Ziel" und der Regler haelt den Durchfluss bei 0 -- fuer immer. Mit
-- Kennlinie faellt die Drehzahl, der Regler legt wieder nach, und die Anlage
-- erholt sich, wie sie es im Spiel auch tut.
--
-- rpm_at_full: Drehzahl bei voller Foerderung; darunter linear. Wer eine
-- feste Drehzahl braucht, uebergibt opts.rpm.
function M.new_turbine_stub(opts)
  opts = opts or {}
  local self = {
    fixed_rpm = opts.rpm,
    rpm_at_full = opts.rpm_at_full or 900,
    flow_for_full = opts.flow_for_full or 1500,
    flow = opts.flow or 2000,
    max_flow = opts.max_flow or 2000,
    coil = opts.coil ~= false,
    energy = opts.energy or 24000,
    active = opts.active ~= false,
  }
  -- Die Drehzahl aus dem Durchfluss. Monoton und ohne Totzeit: der Regler
  -- findet damit immer einen Arbeitspunkt, und ein Durchfluss von 0 bedeutet
  -- auch eine Drehzahl von 0 -- nicht "steht sowieso am Ziel".
  function self.rotor_speed()
    if self.fixed_rpm then return self.fixed_rpm end
    local ratio = self.flow / self.flow_for_full
    if ratio > 1 then ratio = 1 end
    return self.rpm_at_full * ratio
  end

  self.methods = {
    getActive = function() return self.active end,
    setActive = function(v) self.active = v and true or false; return true end,
    getRotorSpeed = function() return self.rotor_speed() end,
    getFluidFlowRateMax = function() return self.flow end,
    setFluidFlowRateMax = function(v)
      local value = tonumber(v) or self.flow
      if value < 0 then value = 0 end
      if value > self.max_flow then value = self.max_flow end
      self.flow = value
      return true
    end,
    getFluidFlowRateMaxMax = function() return self.max_flow end,
    getFluidFlowRate = function() return self.flow end,
    getEnergyProducedLastTick = function() return self.coil and self.energy or 0 end,
    getInductorEngaged = function() return self.coil end,
    setInductorEngaged = function(v) self.coil = v and true or false; return true end,
    getInputAmount = function() return 1000 end,
    getFluidAmountMax = function() return 4000 end,
  }
  return self
end

-- Eine RT-Node mit Reaktor(en) und Turbinen.
--   opts.turbines    Anzahl (Default 3)
--   opts.node_id     Default 'node-101'
-- Rueckgabe: env, plus env.plant = { reactors = {...}, turbines = {...} }
-- fuer den Zugriff auf die Stubs im Test.
function M.new_rt(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 101,
    node_id = opts.node_id or 'node-101',
  })
  env:add_file('/xreactor_config/rt.lua', opts.config or 'return {}\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "rt" }\n')
  env:add_modem(opts.modem or 'modem_0')

  -- reactor_names.lua: die Namen, die der Betreiber seinen Reaktoren gibt.
  --
  -- WICHTIG und leicht zu uebersehen: die Zuordnung geht nach
  -- PERIPHERIENAME, und CC:Tweaked numeriert je Computer. Auf JEDEM RT-Knoten
  -- heissen die Reaktoren "BigReactors-Reactor_1", "_2", ... -- jeder Knoten
  -- braucht also seine EIGENE reactor_names.lua, in der dieselben
  -- Peripherienamen auf andere Klarnamen zeigen ("Reaktor 1"/"Reaktor 2" auf
  -- Knoten 1, "Reaktor 3"/"Reaktor 4" auf Knoten 2, ...).
  --
  -- opts.reactor_aliases: Liste der Klarnamen in Peripherie-Reihenfolge.
  local aliases = opts.reactor_aliases
  if type(aliases) == 'table' and #aliases > 0 then
    local parts = { 'return {', '  version = 2,', '  completed = true,', '  aliases = {' }
    for index, alias in ipairs(aliases) do
      parts[#parts + 1] = string.format('    ["BigReactors-Reactor_%d"] = %q,', index, alias)
    end
    parts[#parts + 1] = '  },'
    parts[#parts + 1] = '  reactors = {},'
    parts[#parts + 1] = '}'
    env:add_file('/xreactor_config/reactor_names.lua', table.concat(parts, '\n') .. '\n')
  end

  local plant = { reactors = {}, turbines = {} }
  for index = 1, (opts.reactors or 1) do
    local name = 'BigReactors-Reactor_' .. index
    -- Je Reaktor eigene Werte erlaubt (opts.reactor_list), sonst fuer alle
    -- dieselben (opts.reactor).
    local spec = opts.reactor_list and opts.reactor_list[index] or opts.reactor
    local stub = M.new_reactor_stub(spec)
    plant.reactors[name] = stub
    plant.reactors[index] = stub
    env:add_peripheral(name, 'BigReactors-Reactor', stub.methods)
  end
  for index = 1, (opts.turbines or 3) do
    local name = 'BigReactors-Turbine_' .. index
    local stub = M.new_turbine_stub(opts.turbine)
    plant.turbines[name] = stub
    plant.turbines[index] = stub
    env:add_peripheral(name, 'BigReactors-Turbine', stub.methods)
  end
  env.plant = plant
  return env:install()
end

-- Die MASTER-Node. Braucht keine Anlagenperipherie -- sie redet nur.
function M.new_master(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 1,
    node_id = opts.node_id or 'master-1',
  })
  env:add_file('/xreactor_config/master.lua', opts.config or 'return {}\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "master" }\n')
  env:add_modem(opts.modem or 'modem_0')
  return env:install()
end

-- Die FUEL-Node mit ME-Bridge und Uebergabepunkt.
--   opts.routes   Inhalt von fuel_routes.lua (String) oder nil
--   opts.enabled  logistics.enabled (Default false, wie im Original)
function M.new_fuel(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 202,
    node_id = opts.node_id or 'fuel-1',
  })
  if opts.routes then
    env:add_file('/xreactor_config/fuel_routes.lua', opts.routes)
  end
  env:add_file('/xreactor_config/fuel.lua',
    'return { logistics = { enabled = ' .. tostring(opts.enabled == true) .. ' } }\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "fuel" }\n')
  env:add_modem(opts.modem or 'modem_0')
  env:add_peripheral('meBridge_0', 'meBridge', {
    listItems = function() return {} end,
    getItem = function() return { amount = opts.me_amount or 5000 } end,
    exportItem = function() return opts.export_moved or 64 end,
    isConnected = function() return true end,
  })
  env:add_peripheral(opts.export_chest or 'chest_0', 'inventory', {
    list = function() return {} end, size = function() return 27 end,
  })
  return env:install()
end

-- Eine ENERGY-Node mit Induktionsmatrix.
--
-- Methodennamen aus adapters/induction_matrix.lua und
-- adapters/energy_storage.lua. Beide Adapter vertragen mehrere Varianten
-- (Mekanism hat sie ueber die Versionen umbenannt) -- hier stehen die
-- heutigen.
function M.new_energy(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 300,
    node_id = opts.node_id or 'energy-1',
  })
  env:add_file('/xreactor_config/energy.lua', opts.config or 'return {}\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "energy" }\n')
  env:add_modem(opts.modem or 'modem_0')

  local matrix = {
    energy = opts.energy or 4.0e9,
    capacity = opts.capacity or 1.0e10,
    last_input = opts.last_input or 120000,
    last_output = opts.last_output or 90000,
  }
  env.matrix = matrix
  env:add_peripheral(opts.matrix_name or 'inductionMatrix_0', 'inductionMatrix', {
    getEnergy = function() return matrix.energy end,
    getMaxEnergy = function() return matrix.capacity end,
    getEnergyStored = function() return matrix.energy end,
    getMaxEnergyStored = function() return matrix.capacity end,
    getStoredPower = function() return matrix.energy end,
    getMaxStoredPower = function() return matrix.capacity end,
    getLastInput = function() return matrix.last_input end,
    getLastOutput = function() return matrix.last_output end,
    getInstalledCells = function() return opts.cells or 36 end,
    getInstalledProviders = function() return opts.providers or 36 end,
    getMultiblockID = function() return opts.matrix_id or 'matrix-aaaa' end,
  })
  return env:install()
end

-- Eine REPROCESSOR-Node mit ME-Bridge und logistischem Sortierer.
function M.new_reprocessor(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 400,
    node_id = opts.node_id or 'reproc-1',
  })
  env:add_file('/xreactor_config/reprocessor.lua', opts.config or 'return {}\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "reprocessor" }\n')
  env:add_modem(opts.modem or 'modem_0')
  env:add_peripheral('meBridge_0', 'meBridge', {
    listItems = function() return {} end,
    getItem = function() return { amount = opts.me_amount or 2000 } end,
    exportItem = function() return opts.export_moved or 32 end,
    importItem = function() return opts.import_moved or 32 end,
    isConnected = function() return true end,
  })
  env:add_peripheral(opts.sorter or 'logisticalSorter_0', 'logisticalSorter', {
    getTransporterMode = function() return true end,
    setTransporterMode = function() return true end,
    getAutoMode = function() return false end,
    setAutoMode = function() return true end,
  })
  return env:install()
end

-- Eine VALVE-Node. Sie schaltet ein Redstone-Ventil und hoert auf ihrem
-- eigenen Kanal (siehe nodes/valve/main.lua). Der Zustand des Ausgangs liegt
-- danach in env.redstone.
function M.new_valve(opts)
  opts = opts or {}
  local env = boot.new({
    computer_id = opts.computer_id or 500,
    node_id = opts.node_id or 'valve-1',
  })
  local config = opts.config
  if config == nil then
    config = string.format('return { node_id = %q }\n', opts.node_id or 'valve-1')
  end
  env:add_file('/xreactor_config/valve.lua', config)
  env:add_file('/xreactor_config/role.lua', 'return { role = "valve" }\n')
  env:add_modem(opts.modem or 'modem_0')
  return env:install()
end

-- Mehrere Rollen hintereinander booten, jede mit eigenem Modulgraphen.
--
-- specs: { { name = 'RT', env = <env>, main = 'nodes/rt/main.lua' }, ... }
-- Die Reihenfolge ist die Bootreihenfolge.
function M.boot_all(specs)
  for index, spec in ipairs(specs) do
    if index > 1 then boot.reset_module_cache() end
    spec.env:activate()
    spec.env:boot(spec.main)
  end
  return specs
end

return M
