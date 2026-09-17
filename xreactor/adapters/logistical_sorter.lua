-- adapters/logistical_sorter.lua
--
-- Mekanism Logistical Sorter adapter. Exposes just enough of the sorter's
-- CC:Tweaked computer API (per Mekanism's own computer_help docs --
-- src/datagen/generated/mekanism/data/mekanism/computer_help/methods.csv
-- in mekanism/Mekanism) to retarget a shared Sorter's default output color
-- at runtime: setDefaultColor()/getDefaultColor(). Items entering the
-- Sorter that don't match one of its own (in-game configured) filters get
-- tagged with this default color, and Mekanism Logistical Transporters
-- carry color-tagged items to the matching colored destination. This lets
-- one shared Sorter+Transporter network reach many physically distinct
-- targets (e.g. one per Reprocessor) without any redstone/valve path
-- switching -- the computer just picks the color before each export.
--
-- setDefaultColor()/getDefaultColor() require the Sorter's security to be
-- set to Public (or the computer to be a trusted player) in-game --
-- Mekanism's own "Requires Public Security" flag on these methods.

local sorter = {}
local warned = {}

-- Falls back to a no-op if the shared logger isn't reachable (e.g. in a
-- minimal test harness that doesn't stub core.utils).
local ok_utils, utils = pcall(require, "core.utils")
local log_impl = (ok_utils and type(utils.log) == "function") and utils.log or function() end

local function log_once(prefix, key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  log_impl(prefix or "SORTER", message, "WARN")
end

-- Exactly the colors the operator's real in-game Mekanism Logistical
-- Sorter actually works with (confirmed 2026-09-17), taken over verbatim
-- rather than guessed/mapped against an assumed EnumColor ordering: black,
-- blue, green, cyan, dark red, purple, orange, light grey, grey, light
-- blue, lime, aqua, red, magenta, yellow, white, brown, pink, plus NONE
-- (the sorter's own default "no color set" state, also explicitly
-- settable via setDefaultColor to reset it). NONE is appended at the end
-- rather than the front so newly added Reprocessor targets keep
-- defaulting to COLORS[1] == "BLACK" (an actual routable color), not to
-- "no filter".
sorter.COLORS = {
  "BLACK", "BLUE", "GREEN", "CYAN", "DARK_RED", "PURPLE", "ORANGE",
  "LIGHT_GRAY", "GRAY", "LIGHT_BLUE", "LIME", "AQUA", "RED", "MAGENTA",
  "YELLOW", "WHITE", "BROWN", "PINK", "NONE",
}

local COLOR_SET = {}
for _, c in ipairs(sorter.COLORS) do
  COLOR_SET[c] = true
end

function sorter.is_valid_color(value)
  return type(value) == "string" and COLOR_SET[value:upper()] == true
end

-- Maps the PREVIOUS (guessed, incorrect) EnumColor names this list used
-- before 2026-09-17 onto the confirmed-correct names above, so a
-- reproc_targets.lua saved under the old list keeps working (and the
-- Router UI keeps showing the actual configured routing color) after an
-- update replaces the code with the corrected COLORS above -- an update
-- must never silently break/lose an already-configured route just because
-- the set of valid color names it validates against changed under it.
-- Deliberately does NOT include "GRAY" or "PINK": both names are STILL
-- valid under the current COLORS list above, referring to the exact same
-- setDefaultColor() call (and therefore the exact same real physical
-- sorter color) as before this fix -- only the names actually REMOVED
-- from the list need remapping to a replacement.
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

local function is_sorter_method_set(methods)
  return methods.setDefaultColor == true and methods.getDefaultColor == true
end

function sorter.detect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then
    return nil
  end
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then
    if not ok then
      log_once(log_prefix, "methods:" .. tostring(name), "Sorter methods failed for " .. tostring(name) .. ": " .. tostring(methods))
    end
    return nil
  end
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
    setDefaultColor = function(color)
      if not peripheral.isPresent(name) then
        return false, "peripheral missing"
      end
      if not sorter.is_valid_color(color) then
        return false, "invalid_color:" .. tostring(color)
      end
      local ok_call, err = pcall(peripheral.call, name, "setDefaultColor", color:upper())
      if not ok_call then
        return false, tostring(err)
      end
      return true
    end,
    getDefaultColor = function()
      if not peripheral.isPresent(name) then
        return nil, "peripheral missing"
      end
      local ok_call, value = pcall(peripheral.call, name, "getDefaultColor")
      if not ok_call then
        return nil, tostring(value)
      end
      return value
    end,
  }
end

return sorter
