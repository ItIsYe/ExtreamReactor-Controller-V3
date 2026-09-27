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
-- Der TATSAECHLICHE Durchsatz, getrennt von der Obergrenze.
--
-- Diese Trennung fehlte, und sie ist der Grund, warum eine Feldmessung
-- nicht auswertbar war: FLOW_METHODS liefert bevorzugt
-- getFluidFlowRateMax -- die per setFluidFlowRateMax gesetzte OBERGRENZE,
-- nicht das, was durch die Turbine laeuft. Beides unter einem Namen zu
-- fuehren heisst, den Stellwert mit dem Messwert zu verwechseln: der
-- Regler liest seine eigene Vorgabe zurueck und haelt sie fuer eine
-- Messung. In einer Aufzeichnung vom 2026-09-27 stieg die Vorgabe auf
-- 11 Turbinen um das 13-fache, waehrend die Drehzahl monoton FIEL -- ob
-- dabei ueberhaupt mehr Dampf floss, liess sich nicht sagen, weil nur die
-- Obergrenze aufgezeichnet war.
local FLOW_ACTUAL_METHODS = { "getFluidFlowRate" }

-- Auch das SCHREIBEN wird ermittelt, nicht angenommen.
--
-- Der Lesepfad ist seit v739 durch has_method() gedeckt und vertraegt
-- zwei Namensvarianten -- der Schreibpfad rief dagegen einen fest
-- verdrahteten Namen, ungeprueft. Kennt die Turbine ihn nicht, scheitert
-- JEDER Schreibversuch, und der Fehler ging ueber log_once() in den
-- Log-Collector, nie auf den Bildschirm. Von aussen sieht das aus wie
-- "der Flow-Regler tut nichts": Drehzahl lesbar, Regler rechnet richtig,
-- am Geraet kommt nichts an.
--
-- adapters/reactor.lua hat es immer richtig gemacht. Dieselbe Regel gilt
-- ab jetzt auch fuer die Turbine, in beide Richtungen.
local SET_FLOW_METHODS = { "setFluidFlowRateMax", "setFluidFlowRate" }
local SET_COIL_METHODS = { "setInductorEngaged" }
local SET_ACTIVE_METHODS = { "setActive" }

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
    flow_actual_method = first_available(set, FLOW_ACTUAL_METHODS),
    set_flow_method = first_available(set, SET_FLOW_METHODS),
    set_coil_method = first_available(set, SET_COIL_METHODS),
    set_active_method = first_available(set, SET_ACTIVE_METHODS),
  }
  -- Unvollstaendig heisst: NICHT merken. Das galt bisher nur fuer die
  -- Drehzahl -- eine Turbine, die beim Bau zwar getRotorSpeed, aber noch
  -- kein getFluidFlowRateMax meldete, wurde dauerhaft ohne Durchfluss-
  -- Methode gemerkt. Ihr Rueckmesswert blieb damit fuer immer unbekannt,
  -- obwohl die Drehzahl sauber las -- genau das Bild aus dem Betrieb.
  if entry.rpm_method and not entry.flow_method then
    log_once(log_prefix, tostring(name) .. ":no-flow-method",
      "Turbine " .. tostring(name) .. " kennt keine der bekannten Durchfluss-Methoden ("
        .. table.concat(FLOW_METHODS, ", ") .. ") -- der Rueckmesswert bleibt unbekannt,"
        .. " es wird bei jedem Takt neu nachgesehen")
    return entry
  end
  if not entry.rpm_method then
    log_once(log_prefix, tostring(name) .. ":no-rpm-method",
      "Turbine " .. tostring(name) .. " kennt keine der bekannten Drehzahl-Methoden ("
        .. table.concat(RPM_METHODS, ", ") .. ") -- Drehzahl bleibt unbekannt,"
        .. " es wird bei jedem Takt neu nachgesehen")
    -- NICHT merken. Ein Multiblock, der noch nicht fertig zusammengesetzt
    -- ist (oder dessen Chunk gerade laedt), meldet eine verkuerzte
    -- Methodenliste -- ohne getRotorSpeed. Dieses Ergebnis dauerhaft zu
    -- merken hiesse: die Drehzahl dieser Turbine bleibt fuer immer
    -- unbekannt, obwohl sie eine Sekunde spaeter lesbar waere. Der Cache
    -- wird sonst nur verworfen, wenn die Peripherie ganz verschwindet
    -- (isPresent false) -- eine fertig gebaute Turbine verschwindet aber
    -- nicht mehr.
    --
    -- Die Folge davon war im Betrieb nicht als Lesefehler zu erkennen,
    -- sondern sah nach einem kaputten Regler aus: ohne Drehzahl faellt die
    -- Turbinenregelung auf ihre Schutzentscheidung zurueck (Durchfluss 0),
    -- die Spule bleibt aus Sicherheitsgruenden stehen, wo sie ist, und das
    -- Einlernen wartet ewig, weil keine Turbine je "am Ziel" ist. Genau
    -- dieses Bild kam aus dem doppelten Aufbau, in dem 25 Turbinen frisch
    -- dazugebaut worden waren.
    --
    -- Der Preis ist ein getMethods() je Takt fuer eine Turbine, die
    -- wirklich keine Drehzahl kennt. Das ist der guenstigere Fehler.
    return entry
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
  -- Nur lesen, wenn es eine ANDERE Methode ist als die fuer `flow` --
  -- sonst waere es derselbe Peripherieaufruf zweimal je Takt.
  local flow_actual
  if caps and caps.flow_actual_method and caps.flow_actual_method ~= caps.flow_method then
    flow_actual = read_number(name, caps.flow_actual_method, log_prefix)
  end
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
      flow_actual = caps ~= nil and caps.flow_actual_method ~= nil,
      energy = has_method(method_set, "getEnergyProducedLastTick"),
      coils = has_method(method_set, "getInductorEngaged")
    },
    schema = {
      active = "boolean",
      rpm = "number",
      flow = "number",
      flow_actual = "number",
      energy = "number",
      coil_engaged = "boolean"
    },
    active = active,
    rpm = rpm,
    flow = flow,
    flow_actual = flow_actual,
    energy = energy,
    -- Welche Methoden dieser Adapter tatsaechlich gebunden hat. Ohne das
    -- ist aus einer Aufzeichnung nicht erkennbar, WAS gelesen und WAS
    -- geschrieben wurde -- und genau daran hing die Auswertung.
    flow_method = caps and caps.flow_method or nil,
    flow_actual_method = caps and caps.flow_actual_method or nil,
    set_flow_method = caps and caps.set_flow_method or nil,
    coil_engaged = coil == true,
    methods = methods
  }
end


-- Ein Stellbefehl, der dauerhaft nicht angenommen wird, ist der Grund
-- dafuer, dass "der Regler nichts tut" -- und er gehoert deshalb auf den
-- Rechner selbst. utils.log()/log_once() routen zum Log-Collector; das
-- ist keine Anzeige.
local shouted = {}
local function shout(key, msg)
  if shouted[key] then return end
  shouted[key] = true
  pcall(print, "[RT] " .. msg)
end

local function write_with(name, candidates, label, value, log_prefix)
  if not name then return nil, "missing peripheral" end
  local caps = capabilities(name, log_prefix)
  if not caps then return nil, "capabilities unknown" end
  local method = first_available(caps.set, candidates)
  if not method then
    local msg = string.format(
      "Turbine %s kennt keine der bekannten %s-Methoden (%s) -- sie laesst sich nicht stellen,"
        .. " der Regler rechnet ins Leere",
      tostring(name), label, table.concat(candidates, ", "))
    log_once(log_prefix, tostring(name) .. ":no-" .. label, msg)
    shout(tostring(name) .. ":no-" .. label, msg)
    return nil, "no method for " .. label
  end
  local ok, err = utils.safe_peripheral_call(name, method, value)
  if err then
    log_once(log_prefix, tostring(name) .. ":" .. method,
      "Turbine " .. label .. " failed for " .. tostring(name) .. ": " .. tostring(err))
    shout(tostring(name) .. ":" .. method .. ":err", string.format(
      "Turbine %s: %s ABGELEHNT (%s) -- %s", tostring(name), label, method, tostring(err)))
  end
  return ok, err
end

function turbine.set_flow(name, value, log_prefix)
  if value == nil then return nil, "missing data" end
  return write_with(name, SET_FLOW_METHODS, "flow", value, log_prefix)
end

function turbine.set_coils(name, enabled, log_prefix)
  return write_with(name, SET_COIL_METHODS, "coil", enabled and true or false, log_prefix)
end

function turbine.set_active(name, enabled, log_prefix)
  return write_with(name, SET_ACTIVE_METHODS, "active", enabled and true or false, log_prefix)
end

return turbine
