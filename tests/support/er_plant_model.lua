-- tests/support/er_plant_model.lua
--
-- Anlagenmodell nach dem QUELLTEXT von Extreme Reactors 2, nicht nach
-- Gefuehl. Gegen diesen Stand gebaut:
--
--   ZeroNoRyouki/ExtremeReactors2, mod_version 2.4.27, minecraft_version
--   1.21.1 (= die Version in ATM10 8.1)
--
-- Die Turbine ist 1:1 aus dem Mod uebernommen. Jede Zeile in tick() hat
-- ihre Entsprechung in TurbineLogic.update(); die Kennzahlen stehen in
-- TurbineVariant.java, TurbineData.java und TurbineGameData.java. Die
-- Quellenangaben stehen jeweils daneben, damit sich das nachpruefen laesst,
-- ohne den Mod-Quelltext danebenzulegen.
--
-- Der Reaktor ist BEWUSST eine Naeherung: seine echte Kette (Bestrahlung ->
-- Brennstoffwaerme -> Reaktorwaerme -> Verdampfung) ist um ein Vielfaches
-- groesser als die Turbine und fuer die Reglerpruefung nicht der Punkt.
-- Modelliert ist, was der Regler von ihm SIEHT: Dampfmenge im Tank,
-- Dampfproduktion als Funktion der Stabstellung, Verbrauch durch die
-- Turbinen, Brennstoff und Temperatur. Wo genaehert wird, steht es dabei.
--
-- ── Was dabei ueber die echte Turbine herauskommt ──────────────────────
--
-- 1. Die Drehzahl ist KEINE Funktion des Durchflusses, sondern ein
--    Integrator: rotorEnergy sammelt (Auftrieb - Spule - Luftwiderstand -
--    Reibung) auf, und rpm = rotorEnergy / (Blaetter * Rotormasse). Eine
--    Stellgroesse wirkt also nicht auf die Drehzahl, sondern auf ihre
--    ABLEITUNG. Genau deshalb ueberschwingt ein reiner P-Regler hier.
-- 2. Die Zeitkonstante waechst mit der Turbine: dieselbe Dampfmenge
--    beschleunigt einen grossen Rotor deutlich langsamer.
-- 3. Die Spule ist kein Beiwerk, sondern der groesste Term der Bilanz.
--    Ein- und Aushaengen aendert das Vorzeichen der Beschleunigung.
-- 4. Die Drehzahl wird vom Mod NICHT begrenzt. getMaxRotorSpeed() taucht
--    nur in der Oberflaeche und im Redstone-Port auf -- in der Simulation
--    steht keine Grenze. Unsere Ueberdrehzahl-Abschaltung ist die einzige.

local M = {}

-- ── Kennzahlen aus dem Mod ───────────────────────────────────────────────

-- TurbineVariant.java (Basic: Zeile 37 ff., Reinforced: Zeile 56 ff.)
M.VARIANTS = {
  basic = {
    max_permitted_flow = 1000,   -- setMaxPermittedFlow(1000)
    base_fluid_per_blade = 15,   -- setBaseFluidPerBlade(15) -- mB
    rotor_drag_coefficient = 0.01,
    max_rotor_speed = 1000.0,    -- NUR Anzeige/Redstone-Port, keine Grenze
    rotor_blade_mass = 8,
    rotor_shaft_mass = 8,
  },
  reinforced = {
    max_permitted_flow = 2000,   -- setMaxPermittedFlow(2000)
    base_fluid_per_blade = 25,   -- setBaseFluidPerBlade(25) -- mB
    rotor_drag_coefficient = 0.01,
    max_rotor_speed = 2000.0,
    rotor_blade_mass = 10,
    rotor_shaft_mass = 10,
  },
}

-- TurbineData.java:381  BASE_BLADE_DRAG_COEFFICIENT
M.BASE_BLADE_DRAG_COEFFICIENT = 0.00025
-- TurbineData.java:378  INDUCTOR_BASE_DRAG_COEFFICIENT = 0.1 * turbineCoilDragMultiplier
M.INDUCTOR_BASE_DRAG_COEFFICIENT = 0.1
-- ReactorGameData.java:234  FluidsRegistry.registerVapor("steam", 10.0f, ...)
M.STEAM_ENERGY_DENSITY = 10.0

-- TurbineGameData.java's registerCoils(): (Effizienz, Bonus, Entnahmerate)
M.COILS = {
  iron      = { efficiency = 1.0,  bonus = 1.0,     extraction = 1.0 },
  copper    = { efficiency = 1.2,  bonus = 1.0,     extraction = 1.2 },
  gold      = { efficiency = 2.0,  bonus = 1.0,     extraction = 1.75 },
  electrum  = { efficiency = 2.5,  bonus = 1.0,     extraction = 2.0 },
  platinum  = { efficiency = 3.0,  bonus = 1.0,     extraction = 2.5 },
  enderium  = { efficiency = 3.0,  bonus = 1.02,    extraction = 3.0 },
  ludicrite = { efficiency = 5.23, bonus = 1.03939, extraction = 3.45 },
  ridiculite= { efficiency = 7.47, bonus = 1.2055,  extraction = 3.46 },
  inanite   = { efficiency = 9.76, bonus = 1.3,     extraction = 6.9328 },
  insanite  = { efficiency = 13.74,bonus = 1.41,    extraction = 6.9328 },
}

-- config/Turbine.java + config/General.java -- alle Standardwerte 1.0.
-- Als Parameter gefuehrt, weil ein Modpack sie ueberschreiben kann.
local DEFAULT_MULTIPLIERS = {
  mass_drag = 1.0, aero_drag = 1.0, coil_drag = 1.0,
  fluid_per_blade = 1.0, power_production = 1.0,
}

-- ── Turbine ──────────────────────────────────────────────────────────────

local Turbine = {}
Turbine.__index = Turbine

-- opts = {
--   variant       = "reinforced" | "basic",
--   shaft_blocks  = Anzahl Wellenbloecke,
--   blades        = Anzahl Rotorblaetter (Bloecke),
--   coil_blocks   = Anzahl Spulenbloecke,
--   coil          = Schluessel aus M.COILS (alle Spulenbloecke gleich),
--   multipliers   = optional, siehe DEFAULT_MULTIPLIERS,
-- }
function M.new_turbine(opts)
  opts = opts or {}
  local variant = M.VARIANTS[opts.variant or "reinforced"]
  assert(variant, "unbekannte Turbinen-Variante: " .. tostring(opts.variant))
  local mult = {}
  for k, v in pairs(DEFAULT_MULTIPLIERS) do mult[k] = (opts.multipliers or {})[k] or v end

  local blades = opts.blades or 28
  local shaft_blocks = opts.shaft_blocks or 7
  local coil_blocks = opts.coil_blocks or 0
  local coil = M.COILS[opts.coil or "enderium"]
  assert(coil, "unbekanntes Spulenmaterial: " .. tostring(opts.coil))

  -- TurbineData.update(): Masse und Blattflaeche aus der Geometrie
  local rotor_mass = blades * variant.rotor_blade_mass + shaft_blocks * variant.rotor_shaft_mass

  -- TurbineData.java:153-154
  local frictional_drag = rotor_mass * variant.rotor_drag_coefficient * mult.mass_drag
  local blade_drag = M.BASE_BLADE_DRAG_COEFFICIENT * blades * mult.aero_drag

  -- TurbineData.java:160-168 -- CoilStats summiert je Block, dann geteilt
  -- durch die Groesse. Bei einheitlichem Material kuerzt sich das zu den
  -- Materialkennzahlen selbst.
  local induction_efficiency, induction_exponent, inductor_drag_coefficient = 0.0, 1.0, 0.0
  if coil_blocks > 0 then
    local sum_eff = coil.efficiency * coil_blocks
    local sum_bonus = coil.bonus * coil_blocks
    local sum_drag = coil.extraction * coil_blocks
    induction_efficiency = (sum_eff * 0.33) / coil_blocks
    induction_exponent = math.max(1.0, sum_bonus / coil_blocks)
    inductor_drag_coefficient = (sum_drag / coil_blocks)
      * (M.INDUCTOR_BASE_DRAG_COEFFICIENT * mult.coil_drag)
  end

  -- TurbineData.java:61
  local input_fluid_per_blade = math.floor(variant.base_fluid_per_blade * mult.fluid_per_blade)

  local self = setmetatable({
    variant_name = opts.variant or "reinforced",
    variant = variant,
    blades = blades,
    shaft_blocks = shaft_blocks,
    coil_blocks = coil_blocks,
    coil_name = opts.coil or "enderium",
    rotor_mass = rotor_mass,
    frictional_drag = frictional_drag,
    blade_drag = blade_drag,
    induction_efficiency = induction_efficiency,
    induction_exponent = induction_exponent,
    inductor_drag_coefficient = inductor_drag_coefficient,
    input_fluid_per_blade = input_fluid_per_blade,
    power_multiplier = mult.power_production,

    -- Laufzeitzustand
    rotor_energy = 0.0,
    active = false,
    inductor_engaged = false,
    max_intake_rate = variant.max_permitted_flow,  -- TurbineData.java:45
    vapor_amount = 0,             -- Dampf im Eingangstank
    vapor_capacity = opts.vapor_capacity or 300000,
    energy_generated_last_tick = 0.0,
    fluid_consumed_last_tick = 0,
    rotor_efficiency_last_tick = 1.0,
  }, Turbine)
  return self
end

-- TurbineData.setMaxIntakeRate() (Zeile 268-270): der Sollwert wird auf
-- [0, maxPermittedFlow] GEKLEMMT und ganzzahlig gemacht. Wer mehr stellt,
-- als die Variante zulaesst, bekommt beim Ruecklesen die Grenze zurueck --
-- nicht den gestellten Wert.
function Turbine:set_max_intake_rate(rate)
  rate = math.floor(tonumber(rate) or 0)
  if rate < 0 then rate = 0 end
  if rate > self.variant.max_permitted_flow then rate = self.variant.max_permitted_flow end
  self.max_intake_rate = rate
end

-- MultiblockTurbine.getRotorSpeed() (Zeile 298-308)
function Turbine:rotor_speed()
  if self.blades <= 0 or self.rotor_mass <= 0 then return 0.0 end
  return self.rotor_energy / (self.blades * self.rotor_mass)
end

-- TurbineLogic.update() -- ein Minecraft-Tick (50 ms).
function Turbine:tick()
  local vapor_amount = 0
  self.energy_generated_last_tick = 0.0
  self.fluid_consumed_last_tick = 0

  if self.active then
    vapor_amount = math.min(self.max_intake_rate, self.vapor_amount)
  end

  if vapor_amount > 0 or self.rotor_energy > 0 then
    local rotor_speed = self:rotor_speed()
    local aerodynamic_drag_torque = rotor_speed * self.blade_drag
    local lift_torque = 0.0

    if vapor_amount > 0 then
      local density = M.STEAM_ENERGY_DENSITY
      -- Mehr Dampf als die Blattflaeche verarbeiten kann wird nur noch
      -- anteilig genutzt -- und trotzdem VOLL verbraucht.
      local steam_to_process = self.blades * self.input_fluid_per_blade
      steam_to_process = math.min(steam_to_process, vapor_amount)
      lift_torque = steam_to_process * density

      if steam_to_process < vapor_amount then
        local rest = vapor_amount - steam_to_process
        -- Ganzzahlige Division wie in Java ("round in the player's favor")
        local needed_blades = math.floor(vapor_amount / self.input_fluid_per_blade)
        local missing_blades = needed_blades - self.blades
        local blade_efficiency = 1.0 - (missing_blades / needed_blades)
        lift_torque = lift_torque + rest * density * blade_efficiency
        self.rotor_efficiency_last_tick = lift_torque / (vapor_amount * density)
      else
        self.rotor_efficiency_last_tick = 1.0
      end
    end

    local induction_torque = 0.0
    if self.inductor_engaged then
      induction_torque = rotor_speed * self.inductor_drag_coefficient * self.coil_blocks
    end

    local energy_to_generate = (induction_torque ^ self.induction_exponent) * self.induction_efficiency
    if energy_to_generate > 0.0 then
      -- Wirkungsgradkurve: Maxima bei 900 und 1800 RPM, darunter 500 RPM
      -- hart auf 0.5 gedeckelt.
      local efficiency = 0.25 * math.cos(rotor_speed / (45.5 * math.pi)) + 0.75
      if rotor_speed < 500 then efficiency = math.min(0.5, efficiency) end
      self.energy_generated_last_tick = energy_to_generate * efficiency * self.power_multiplier
    end

    self.rotor_energy = self.rotor_energy
      + lift_torque - induction_torque - aerodynamic_drag_torque - self.frictional_drag
    if self.rotor_energy < 0 then self.rotor_energy = 0 end

    if vapor_amount > 0 then
      self.vapor_amount = self.vapor_amount - vapor_amount
      self.fluid_consumed_last_tick = vapor_amount
    end
  end
end

-- ── Reaktor (Naeherung, siehe Kopf) ──────────────────────────────────────

local Reactor = {}
Reactor.__index = Reactor

function M.new_reactor(opts)
  opts = opts or {}
  return setmetatable({
    active = false,
    rods = 100,                -- 100 = voll eingefahren = keine Leistung
    steam = 0,
    steam_capacity = opts.steam_capacity or 100000,
    -- Dampfleistung bei voll ausgefahrenen Staeben. Frei waehlbar, damit
    -- sich sowohl eine ueberdimensionierte als auch eine knapp
    -- ausgelegte Anlage pruefen laesst.
    max_steam_per_tick = opts.max_steam_per_tick or 20000,
    fuel = opts.fuel or 4000,
    fuel_capacity = opts.fuel_capacity or 4000,
    waste = 0,
    coolant = opts.coolant or 9000,
    coolant_capacity = opts.coolant_capacity or 10000,
    fuel_temperature = 300,
    -- Traegheit der Waermekette: die Dampfproduktion folgt der
    -- Stabstellung nicht sofort. Ein Tick = 50 ms.
    thermal_lag = opts.thermal_lag or 0.02,
    _steam_rate = 0,
    fuel_burn_per_steam = opts.fuel_burn_per_steam or 0.0000004,
  }, Reactor)
end

function Reactor:tick()
  local demand = 0
  if self.active and self.fuel > 0 then
    demand = math.max(0, (100 - self.rods) / 100) * self.max_steam_per_tick
  end
  self._steam_rate = self._steam_rate + (demand - self._steam_rate) * self.thermal_lag
  local produced = math.floor(self._steam_rate)
  local space = self.steam_capacity - self.steam
  if produced > space then produced = space end
  if produced < 0 then produced = 0 end
  self.steam = self.steam + produced
  -- Brennstoff und Temperatur folgen der Leistung, grob.
  self.fuel = math.max(0, self.fuel - produced * self.fuel_burn_per_steam)
  self.waste = math.min(self.fuel_capacity, self.waste + produced * self.fuel_burn_per_steam * 0.25)
  local target_temp = 300 + (self._steam_rate / math.max(1, self.max_steam_per_tick)) * 1200
  self.fuel_temperature = self.fuel_temperature + (target_temp - self.fuel_temperature) * self.thermal_lag
  return produced
end

-- ── Anlage: Reaktor + Turbinen an einem Dampfnetz ────────────────────────

local Plant = {}
Plant.__index = Plant

function M.new_plant(opts)
  opts = opts or {}
  return setmetatable({
    reactor = opts.reactor or M.new_reactor(),
    turbines = opts.turbines or {},
    turbine_order = opts.turbine_order or {},
    ticks = 0,
  }, Plant)
end

-- Ein Minecraft-Tick der ganzen Anlage. Der Dampf wird anteilig nach
-- Anforderung verteilt -- reicht er nicht, bekommt jede Turbine denselben
-- Bruchteil. Das ist die Eigenschaft, auf die es ankommt: alle Turbinen
-- haengen an EINEM Budget, eine Turbine mehr nimmt allen anderen etwas weg.
function Plant:tick()
  self.ticks = self.ticks + 1
  self.reactor:tick()

  local demand = 0
  for _, t in pairs(self.turbines) do
    if t.active then
      local want = t.max_intake_rate - t.vapor_amount
      if want > 0 then demand = demand + want end
    end
  end

  if demand > 0 then
    local available = self.reactor.steam
    local share = math.min(1.0, available / demand)
    local drawn = 0
    for _, t in pairs(self.turbines) do
      if t.active then
        local want = t.max_intake_rate - t.vapor_amount
        if want > 0 then
          local got = math.floor(want * share)
          t.vapor_amount = t.vapor_amount + got
          drawn = drawn + got
        end
      end
    end
    self.reactor.steam = math.max(0, self.reactor.steam - drawn)
  end

  for _, t in pairs(self.turbines) do t:tick() end
end

function Plant:total_output()
  local sum = 0
  for _, t in pairs(self.turbines) do sum = sum + t.energy_generated_last_tick end
  return sum
end

return M
