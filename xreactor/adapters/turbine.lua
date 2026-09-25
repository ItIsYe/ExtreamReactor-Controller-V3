local utils = require("core.utils")

local turbine = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  utils.log(prefix or "TURBINE", message, "WARN")
end

local function safe_call(name, method, log_prefix, ...)
  if not method then
    return nil
  end
  local result, err = utils.safe_peripheral_call(name, method, ...)
  if err then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method), "Turbine call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(err))
  end
  return result
end

local function read_number(name, method, log_prefix)
  local value = safe_call(name, method, log_prefix)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then
      return parsed
    end
  end
  if value ~= nil then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method) .. ":type", "Turbine metric type mismatch peripheral=" .. tostring(name) .. " method=" .. tostring(method) .. " type=" .. type(value) .. " value=" .. tostring(value))
  end
  return "n/a"
end

local function has_method(set, key)
  return set and set[key] == true
end

-- ── Faehigkeiten je Peripherie, EINMAL ermittelt ─────────────────────────
--
-- Warum gemerkt statt jedes Mal neu gefragt:
--
-- CC:Tweaked wirft bei einer unbekannten Methode einen Lua-Fehler
-- ("No such method <name>", PeripheralAPI's PeripheralWrapper.call()).
-- utils.safe_peripheral_call() faengt den ab, read_number() macht daraus
-- den String "n/a" -- also einen NICHT lesbaren Messwert.
--
-- Genau das ist im Livetest auf node-101 passiert: inspect() hat die
-- Methodenliste bei JEDEM Aufruf neu geholt (25 Turbinen, mehrmals pro
-- Sekunde). Schlaegt utils.safe_get_methods() dabei einmal fehl -- ein
-- Rennen gegen ein kurz nicht erreichbares Peripheral, mehr braucht es
-- nicht --, war die Liste leer, und die Zeile darunter fiel auf
-- "getRotorRPM" zurueck. Die gibt es bei Extreme Reactors 2 nicht. Der
-- Ausweichweg war damit ein garantierter Fehlschlag, kein Ausweichweg.
--
-- Zwei Konsequenzen daraus, beide hier umgesetzt:
--
--   * Die Liste wird gemerkt. Ein fehlgeschlagener Versuch behaelt die
--     zuletzt bekannte, statt auf "leer" zusammenzufallen. Nebenbei
--     spart das je Turbine und Takt einen Peripherieaufruf.
--   * Es wird NIE eine Methode aufgerufen, von der nicht bekannt ist,
--     dass es sie gibt -- genauso, wie adapters/reactor.lua es schon
--     immer gehalten hat. Ist die Liste unbekannt, ist der Messwert
--     eben unbekannt; erfunden wird nichts.
local capability_cache = {}

-- Kandidaten in der Reihenfolge, in der sie probiert werden. Extreme
-- Reactors 2 (MC 1.21.1) nennt die Drehzahl getRotorSpeed; getRotorRPM
-- stammt aus der Big-Reactors-Aera und existiert dort nicht mehr.
local RPM_METHODS  = { "getRotorSpeed", "getRotorRPM" }
local FLOW_METHODS = { "getFluidFlowRateMax", "getFluidFlowRate" }

local function first_available(set, candidates)
  for _, method in ipairs(candidates) do
    if has_method(set, method) then return method end
  end
  return nil
end

-- Gibt die Methodenmenge zurueck, oder nil wenn sie (noch) unbekannt ist.
local function capabilities(name, log_prefix)
  local cached = capability_cache[name]
  if cached then return cached end

  local methods, err = utils.safe_get_methods(name)
  if type(methods) ~= "table" then
    log_once(log_prefix, tostring(name) .. ":getMethods",
      "Turbine capabilities not readable for " .. tostring(name) .. ": " .. tostring(err)
        .. " -- Messwerte gelten diesen Takt als unbekannt (es wird nichts geraten)")
    return nil
  end

  local set = {}
  for _, method in ipairs(methods) do set[method] = true end
  local entry = {
    methods = methods, set = set,
    rpm_method = first_available(set, RPM_METHODS),
    flow_method = first_available(set, FLOW_METHODS),
  }
  if not entry.rpm_method then
    log_once(log_prefix, tostring(name) .. ":no-rpm-method",
      "Turbine " .. tostring(name) .. " kennt keine der bekannten Drehzahl-Methoden ("
        .. table.concat(RPM_METHODS, ", ") .. ") -- Drehzahl bleibt unbekannt")
  end
  capability_cache[name] = entry
  return entry
end

-- Sichtbar fuer Tests und fuer den Fall, dass eine Turbine ausgetauscht
-- wird: beim naechsten inspect() wird neu ermittelt.
function turbine.forget_capabilities(name)
  if name then capability_cache[name] = nil else capability_cache = {} end
end

function turbine.inspect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    -- Weg -- vielleicht kommt an diesem Namen spaeter eine andere
    -- Turbine zurueck, also nicht auf alten Faehigkeiten sitzen bleiben.
    if name then capability_cache[name] = nil end
    return nil, "peripheral missing"
  end
  local type_name = peripheral.getType(name) or "turbine"
  local caps = capabilities(name, log_prefix)
  local method_set = caps and caps.set or nil
  local methods = caps and caps.methods or {}

  -- Jeder Aufruf nur, wenn die Methode nachweislich existiert. Ohne
  -- bekannte Faehigkeiten bleibt alles unbekannt -- read_number() liefert
  -- dann "n/a", und rt2_adapter.read_turbine() macht daraus nil. Der
  -- Regler faehrt daraufhin auf die sichere Seite (Dampf auf null), statt
  -- gegen erfundene Werte zu regeln.
  local active = has_method(method_set, "getActive")
    and (safe_call(name, "getActive", log_prefix) == true) or false
  local rpm = read_number(name, caps and caps.rpm_method or nil, log_prefix)
  local flow = read_number(name, caps and caps.flow_method or nil, log_prefix)
  local energy = read_number(name,
    has_method(method_set, "getEnergyProducedLastTick") and "getEnergyProducedLastTick" or nil, log_prefix)
  local coil = has_method(method_set, "getInductorEngaged")
    and safe_call(name, "getInductorEngaged", log_prefix) or nil
  return {
    name = name,
    type = type_name,
    adapter = "turbine",
    features = {
      active = has_method(method_set, "getActive"),
      rpm = caps ~= nil and caps.rpm_method ~= nil,
      flow = caps ~= nil and caps.flow_method ~= nil,
      energy = has_method(method_set, "getEnergyProducedLastTick"),
      coils = has_method(method_set, "getInductorEngaged")
    },
    schema = {
      active = "boolean",
      rpm = "number",
      flow = "number",
      energy = "number",
      coil_engaged = "boolean"
    },
    active = active,
    rpm = rpm,
    flow = flow,
    energy = energy,
    coil_engaged = coil == true,
    methods = methods
  }
end

function turbine.set_active(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setActive", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setActive", "Turbine active failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

function turbine.set_flow(name, value, log_prefix)
  if not name or value == nil then return nil, "missing data" end
  local ok, err = utils.safe_peripheral_call(name, "setFluidFlowRateMax", value)
  if err then
    log_once(log_prefix, tostring(name) .. ":setFluidFlowRateMax", "Turbine flow failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

function turbine.set_coils(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setInductorEngaged", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setInductorEngaged", "Turbine coil failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

return turbine
