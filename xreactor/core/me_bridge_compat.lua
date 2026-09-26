-- core/me_bridge_compat.lua
--
-- Advanced Peripherals hat die Item-API der ME/RS Bridge mehrfach
-- umgebaut. Die 0.7er Dokumentation nennt
--
--     exportItemToPeripheral(item: table, container: string)
--     exportItem(item: table, direction: string)
--
-- und genau so wurde hier bisher aufgerufen. Im Betrieb (MC 1.21.1,
-- ATM10) antwortet die Bridge darauf jedoch mit
--
--     bad argument #1 (string expected, got table)
--
-- Das ist CC:Tweakeds eigene Pruefung der Java-Parameter: diese Bridge
-- erwartet an Position 1 KEINE Tabelle. Dieselbe Dokumentation vermerkt,
-- dass mit 0.8 ein neues ME/RS-Bridge-System kommt -- die 1.21-Fassung
-- folgt also einer anderen Konvention, und welche das ist, steht in
-- keiner erreichbaren Quelle verlaesslich fuer jede Spielversion.
--
-- Deshalb wird hier NICHT geraten. Der Aufruf probiert die bekannten
-- Konventionen der Reihe nach durch und merkt sich die erste, die von
-- der Peripherie angenommen wird. Genau dasselbe Vorgehen wie bei den
-- Turbinen-Methodennamen in adapters/turbine.lua: einmal messen statt
-- dauerhaft annehmen.
--
-- Sicher ist das, weil nur nach einem ARGUMENTFEHLER weitergeprobiert
-- wird. Ein Argumentfehler entsteht, bevor der Mod irgendetwas bewegt --
-- ein Fehlversuch kann also nichts verschieben. Jede andere Fehlerart
-- (unbekannter Behaelter, leerer Bestand) gilt als endgueltige Antwort
-- und wird unveraendert durchgereicht.

local M = {}

-- getItem/getFluid exist unchanged across both generations; only the
-- import/export method names differ. A caller may only ever need one
-- direction (e.g. feed_router.lua only ever exports, never imports), so
-- detection only requires getItem plus at least one transfer method from
-- either generation -- not both directions.
function M.is_bridge(method_set)
  return method_set.getItem ~= nil
    and (method_set.importItem or method_set.importItemFromPeripheral
      or method_set.exportItem or method_set.exportItemToPeripheral) ~= nil
end

-- Die Konventionen, in der Reihenfolge, in der sie versucht werden. Die
-- dokumentierte 0.7er zuerst -- wo sie laeuft, aendert sich nichts.
local CONVENTIONS = {
  { id = "filter_target", build = function(filter, target) return filter, target end },
  { id = "target_filter", build = function(filter, target) return target, filter end },
  { id = "name_count_target", build = function(filter, target)
      return filter.name, tonumber(filter.count) or 1, target
    end },
  { id = "target_name_count", build = function(filter, target)
      return target, filter.name, tonumber(filter.count) or 1
    end },
}

M.CONVENTIONS = CONVENTIONS

-- Gemerkt je Methodenname, nicht je Peripherie: eine Welt hat genau eine
-- Mod-Fassung, und ein Bridge-Wechsel im laufenden Betrieb kommt nicht vor.
local learned = {}

function M.forget_conventions() learned = {} end

-- Welche Konvention fuer diese Methode gilt (nil = noch nicht ermittelt).
function M.learned_convention(method_name) return learned[method_name] end

-- Ein Argumentfehler heisst: die Signatur passt nicht. Der Mod hat dann
-- noch nichts angefasst, ein weiterer Versuch ist gefahrlos.
local function is_signature_error(err)
  local text = tostring(err or ""):lower()
  return text:find("bad argument", 1, true) ~= nil
    or text:find("expected", 1, true) ~= nil
end

local function call_with_conventions(bridge, method_name, filter, target)
  local method = bridge[method_name]
  if type(method) ~= "function" then return nil, "no_method:" .. method_name, nil end

  local remembered = learned[method_name]
  if remembered then
    local ok, result = pcall(method, remembered.build(filter, target))
    -- Auch eine gemerkte Konvention wird wieder verworfen, wenn sie
    -- ploetzlich an der Signatur scheitert (anderer Mod-Stand nach einem
    -- Update) -- dann wird neu gemessen statt dauerhaft zu scheitern.
    if ok or not is_signature_error(result) then return ok, result, remembered.id end
    learned[method_name] = nil
  end

  local first_error = nil
  for _, convention in ipairs(CONVENTIONS) do
    local ok, result = pcall(method, convention.build(filter, target))
    if ok then
      learned[method_name] = convention
      return true, result, convention.id
    end
    first_error = first_error or result
    if not is_signature_error(result) then
      -- Keine Signaturfrage, sondern eine echte Antwort der Bridge
      -- (unbekannter Behaelter, kein Bestand). Weiterprobieren wuerde
      -- die Aussage nur verschleiern.
      return false, result, convention.id
    end
  end
  return false, first_error, nil
end

-- target_name ist an jeder Aufrufstelle dieses Projekts ein
-- Peripherie-Name, nie eine Redstone-Seite.
function M.export_to(bridge, filter, target_name)
  local method_name = bridge.exportItemToPeripheral and "exportItemToPeripheral" or "exportItem"
  return call_with_conventions(bridge, method_name, filter, target_name)
end

function M.import_from(bridge, filter, source_name)
  local method_name = bridge.importItemFromPeripheral and "importItemFromPeripheral" or "importItem"
  return call_with_conventions(bridge, method_name, filter, source_name)
end

-- Fuer die Fehlermeldung: was diese Bridge ueberhaupt anbietet. Bei einem
-- Signatur-Streit ist das die einzige belastbare Auskunft -- sie sagt,
-- welche Fassung wirklich installiert ist, statt sie zu vermuten.
function M.transfer_methods(bridge)
  local names = {}
  if type(bridge) == "table" then
    for key, value in pairs(bridge) do
      if type(value) == "function" and type(key) == "string"
          and (key:find("port", 1, true) or key:find("Item", 1, true)) then
        names[#names + 1] = key
      end
    end
  end
  table.sort(names)
  return names
end

-- The old API's Item Stack used `.amount`; keep accepting `.count` too in
-- case a given mod version renamed the field.
function M.item_amount(info)
  if type(info) ~= "table" then return 0 end
  return tonumber(info.amount) or tonumber(info.count) or 0
end

return M
