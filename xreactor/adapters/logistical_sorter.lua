-- adapters/logistical_sorter.lua
--
-- Mekanism Logistical Sorter adapter. Exposes just enough of the sorter's
-- CC:Tweaked computer API (per Mekanism's own computer_help docs --
-- src/datagen/generated/mekanism/data/mekanism/computer_help/methods.csv
-- in mekanism/Mekanism) to retarget a shared Sorter's default output color
-- at runtime: setDefaultColor()/clearDefaultColor()/getDefaultColor().
-- Items entering the Sorter that don't match one of its own (in-game
-- configured) filters get tagged with this default color, and Mekanism
-- Logistical Transporters carry color-tagged items to the matching colored
-- destination. This lets one shared Sorter+Transporter network reach many
-- physically distinct targets (e.g. one per Reprocessor) without any
-- redstone/valve path switching -- the computer just picks the color
-- before each export.
--
-- setDefaultColor()/clearDefaultColor() require the Sorter's security to
-- be set to Public in-game -- Mekanism's own "Requires Public Security"
-- flag on these methods. getDefaultColor() does not.
--
-- ZWEI NAMEN JE FARBE (v826): Mekanism zeigt im Spiel andere Namen an, als
-- seine Computer-Schnittstelle annimmt. mekanism.api.text.EnumColor:
--   DARK_BLUE heisst im Spiel "Blue", DARK_GREEN "Green", DARK_AQUA
--   "Cyan", GRAY "Light Gray", DARK_GRAY "Gray", INDIGO "Light Blue",
--   BRIGHT_GREEN "Lime", PINK "Magenta", BRIGHT_PINK "Pink".
-- setDefaultColor() nimmt NUR die Konstantennamen (SpecialConverters.
-- sanitizeStringToEnum, Gross/klein egal); alles andere ist ein Fehler.
-- Die Liste unten (COLORS) traegt seit 2026-09-17 die Namen aus dem Spiel
-- -- so stehen sie in Router-UI und gespeicherten Zielen, und so bleiben
-- sie auch. Bis v825 gingen diese Namen aber unuebersetzt an den Sorter:
-- BLUE, GREEN, CYAN, LIGHT_GRAY, LIGHT_BLUE, LIME, MAGENTA scheiterten
-- (Feed uebersprungen, kein Farbwechsel), GRAY setzte Hellgrau und PINK
-- Magenta. Jetzt uebersetzt MEKANISM_NAME erst beim Senden, und eine
-- Rueckleseprobe (getDefaultColor) bestaetigt, dass die Farbe sitzt.

local sorter = {}

-- Falls back to a no-op if the shared logger isn't reachable (e.g. in a
-- minimal test harness that doesn't stub core.utils).
local ok_utils, utils = pcall(require, "core.utils")
local log_impl = (ok_utils and type(utils.log) == "function") and utils.log or function() end


-- getMethods-Fehlschlag einmal je Stoerung statt einmal je Laufzeit
-- (core/once_log.lua): klappt das Erkennen wieder, wird die naechste
-- Stoerung erneut gemeldet.
local methods_once = require("core.once_log").new()

-- Die Farben so, wie der Betreiber sie im Spiel am Sorter sieht (bestaetigt
-- 2026-09-17): black, blue, green, cyan, dark red, purple, orange, light
-- grey, grey, light blue, lime, aqua, red, magenta, yellow, white, brown,
-- pink -- plus NONE (keine Farbe gesetzt). Das sind die Namen in Router-UI
-- und gespeicherten Zielen; an den Sorter geht MEKANISM_NAME[...] (unten).
-- NONE steht am Ende, damit neue Ziele weiter mit COLORS[1] == "BLACK"
-- (einer echten Farbe) vorbelegt werden, nicht mit "keine Farbe".
sorter.COLORS = {
  "BLACK", "BLUE", "GREEN", "CYAN", "DARK_RED", "PURPLE", "ORANGE",
  "LIGHT_GRAY", "GRAY", "LIGHT_BLUE", "LIME", "AQUA", "RED", "MAGENTA",
  "YELLOW", "WHITE", "BROWN", "PINK", "NONE",
}

-- Name im Spiel (COLORS) -> Konstantenname in mekanism.api.text.EnumColor,
-- den setDefaultColor() annimmt und getDefaultColor() zurueckgibt.
-- NONE fehlt absichtlich: "keine Farbe" ist clearDefaultColor().
local MEKANISM_NAME = {
  BLACK      = "BLACK",
  BLUE       = "DARK_BLUE",
  GREEN      = "DARK_GREEN",
  CYAN       = "DARK_AQUA",
  DARK_RED   = "DARK_RED",
  PURPLE     = "PURPLE",
  ORANGE     = "ORANGE",
  LIGHT_GRAY = "GRAY",
  GRAY       = "DARK_GRAY",
  LIGHT_BLUE = "INDIGO",
  LIME       = "BRIGHT_GREEN",
  AQUA       = "AQUA",
  RED        = "RED",
  MAGENTA    = "PINK",
  YELLOW     = "YELLOW",
  WHITE      = "WHITE",
  BROWN      = "BROWN",
  PINK       = "BRIGHT_PINK",
}

local DISPLAY_NAME = {}
for display, mekanism in pairs(MEKANISM_NAME) do
  DISPLAY_NAME[mekanism] = display
end

local COLOR_SET = {}
for _, c in ipairs(sorter.COLORS) do
  COLOR_SET[c] = true
end

function sorter.is_valid_color(value)
  return type(value) == "string" and COLOR_SET[value:upper()] == true
end

-- Name im Spiel -> Mekanisms Konstantenname; nil fuer NONE und Unbekanntes.
function sorter.mekanism_name(color)
  if type(color) ~= "string" then return nil end
  return MEKANISM_NAME[color:upper()]
end

-- Mekanisms Konstantenname (wie getDefaultColor() ihn liefert) -> Name im
-- Spiel; nil/leer -> "NONE"; Unbekanntes -> nil.
function sorter.display_name(mekanism)
  if mekanism == nil or mekanism == "" then return "NONE" end
  if type(mekanism) ~= "string" then return nil end
  return DISPLAY_NAME[mekanism:upper()]
end

-- Ziele, die VOR 2026-09-17 gespeichert wurden, tragen Mekanisms
-- Konstantennamen. Die werden beim Laden auf den Namen im Spiel umgestellt
-- (config_normalizer.lua), damit die Router-UI dieselben Namen zeigt wie
-- das Spiel -- MEKANISM_NAME uebersetzt beim Senden zurueck auf dieselbe
-- Konstante, die Route bleibt also physisch dieselbe.
-- GRAY und PINK fehlen hier, weil beide auch Namen im Spiel sind (Gray,
-- Pink): ein gespeichertes GRAY/PINK bleibt, wie es ist, und meint seit
-- 2026-09-17 die Farbe, die die Router-UI anzeigt.
local LEGACY_COLOR_MIGRATION = {
  DARK_BLUE = "BLUE",
  DARK_GREEN = "GREEN",
  DARK_AQUA = "CYAN",
  DARK_GRAY = "GRAY",
  INDIGO = "LIGHT_BLUE",
  BRIGHT_GREEN = "LIME",
  BRIGHT_PINK = "PINK",
}

-- Returns the migrated color (uppercased) if `value` was a valid color
-- under the previous list, or nil if it's not a recognised legacy name.
-- Callers should try sorter.is_valid_color() FIRST (a color valid under
-- the CURRENT list must never be remapped) and only fall back to this for
-- values that are not currently valid.
function sorter.migrate_legacy_color(value)
  if type(value) ~= "string" then return nil end
  return LEGACY_COLOR_MIGRATION[value:upper()]
end

-- setDefaultColor/getDefaultColor alone as the detection signature is
-- fragile: Mekanism's "Requires Public Security" flag on setDefaultColor
-- means peripheral.getMethods() can omit the color methods for a Sorter
-- whose in-game security is still at its default (non-Public) level, even
-- though the block is physically present and fully wired -- detect() then
-- returned nil and callers logged "Sorter nicht gefunden", hiding the
-- real, fixable cause (a security setting) behind a message that reads
-- like a missing/miswired peripheral. setAutoMode is present on every
-- Logistical Sorter (nodes/valve/controller.lua relies on exactly this
-- method to recognise a Sorter), so accepting EITHER signature still only
-- matches a real Sorter (never a chest/transporter), while making
-- detection itself independent of the security setting. The actual
-- security requirement still applies when a call is made -- see
-- setDefaultColor() below, which surfaces that failure explicitly instead
-- of pretending the Sorter was never found.
local function is_sorter_method_set(methods)
  return (methods.setDefaultColor == true and methods.getDefaultColor == true)
    or methods.setAutoMode == true
end

-- Liest die aktuelle Default-Farbe roh (Mekanisms Konstantenname, nil =
-- keine Farbe). Zweiter Rueckgabewert: Fehlertext, wenn der Aufruf selbst
-- scheiterte.
local function read_raw_color(name)
  local ok_call, value = pcall(peripheral.call, name, "getDefaultColor")
  if not ok_call then
    return nil, tostring(value)
  end
  if type(value) == "string" and value ~= "" then
    return value:upper(), nil
  end
  return nil, nil
end

function sorter.detect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    if not ok then
      if methods_once.report(name, "methods") then
        log_impl(log_prefix or "SORTER", "Sorter methods failed for " .. tostring(name) .. ": " .. tostring(methods), "WARN")
      end
    end
    return nil
  end
  methods_once.recover(name, "methods")
  local method_set = {}
  for _, m in ipairs(methods) do
    method_set[m] = true
  end
  if not is_sorter_method_set(method_set) then
    return nil
  end
  local type_name = peripheral.getType(name) or "logistical_sorter"

  return {
    name = name,
    type = type_name,
    getMethodList = function()
      return methods
    end,
    isValid = function()
      return peripheral.isPresent(name)
    end,
    -- color: Name im Spiel (COLORS). Setzt die Farbe ueber Mekanisms
    -- Konstantennamen (NONE: clearDefaultColor) und liest sie zur Probe
    -- zurueck. true nur, wenn der Sorter die Farbe wirklich traegt.
    setDefaultColor = function(color)
      if not peripheral.isPresent(name) then
        return false, "peripheral missing"
      end
      if not sorter.is_valid_color(color) then
        return false, "invalid_color:" .. tostring(color)
      end
      local expected = sorter.mekanism_name(color) -- nil bei NONE
      local ok_call, err
      if expected then
        ok_call, err = pcall(peripheral.call, name, "setDefaultColor", expected)
      else
        ok_call, err = pcall(peripheral.call, name, "clearDefaultColor")
      end
      if not ok_call then
        return false, tostring(err)
      end
      local actual, read_err = read_raw_color(name)
      if read_err then
        return false, "color_readback_failed:" .. read_err
      end
      if actual ~= expected then
        return false, string.format("color_not_applied: erwartet %s (%s), Sorter meldet %s",
          color:upper(), tostring(expected or "keine Farbe"), tostring(actual or "keine Farbe"))
      end
      return true
    end,
    -- Einmalig vor dem Befuellen (v827, nodes/reprocessor/feed_router.lua):
    --   Single Item AUS -- sonst holt der Sorter alle 0,5 s genau EIN Item
    --     aus der Kiste und die Barren gehen einzeln raus;
    --   Auto AN -- nur im Auto-Modus schickt Mekanism Items ohne passenden
    --     Filter mit der Standardfarbe los (TileEntityLogisticalSorter:
    --     "if (!sentItems && autoEject)").
    -- Beides braucht Sicherheit "Oeffentlich". Rueckleseprobe ueber
    -- isSingle()/getAutoMode() (nicht sicherheitsgebunden).
    prepare_for_feeding = function()
      if not peripheral.isPresent(name) then
        return false, "peripheral missing"
      end
      local ok_single, single_err = pcall(peripheral.call, name, "setSingle", false)
      if not ok_single then
        return false, "setSingle:" .. tostring(single_err)
      end
      local ok_auto, auto_err = pcall(peripheral.call, name, "setAutoMode", true)
      if not ok_auto then
        return false, "setAutoMode:" .. tostring(auto_err)
      end
      local ok_read_single, single = pcall(peripheral.call, name, "isSingle")
      local ok_read_auto, auto = pcall(peripheral.call, name, "getAutoMode")
      if not ok_read_single or not ok_read_auto then
        return false, "settings_readback_failed:"
          .. tostring(not ok_read_single and single or auto)
      end
      if single ~= false or auto ~= true then
        return false, string.format("settings_not_applied: Single Item=%s, Auto=%s",
          tostring(single), tostring(auto))
      end
      return true
    end,
    -- Liefert den Namen im Spiel (COLORS), "NONE" ohne Farbe.
    getDefaultColor = function()
      if not peripheral.isPresent(name) then
        return nil, "peripheral missing"
      end
      local raw, read_err = read_raw_color(name)
      if read_err then
        return nil, read_err
      end
      local display = sorter.display_name(raw)
      if not display then
        return nil, "unknown_color:" .. tostring(raw)
      end
      return display
    end,
  }
end

return sorter
