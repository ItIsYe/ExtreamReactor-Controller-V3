-- tests/support/fake_mekanism_sorter.lua
--
-- Nachbildung eines Mekanism Logistical Sorters fuer Tests -- so streng wie
-- das Original (Mekanism 1.21.x, TileEntityLogisticalSorter):
--   setDefaultColor(color)  nimmt NUR Konstantennamen aus
--                           mekanism.api.text.EnumColor (Gross/klein egal,
--                           SpecialConverters.sanitizeStringToEnum), sonst
--                           Fehler; braucht Sicherheit "Oeffentlich".
--   clearDefaultColor()     keine Farbe; braucht Sicherheit "Oeffentlich".
--   getDefaultColor()       Konstantenname oder nil (keine Farbe).
--
-- Bis v825 nahmen die Attrappen der REPROC-Tests JEDEN Farbnamen an -- so
-- blieb unbemerkt, dass der echte Sorter BLUE, GREEN, CYAN, LIGHT_GRAY,
-- LIGHT_BLUE, LIME und MAGENTA ablehnt.

local M = {}

-- Reihenfolge wie in EnumColor.java.
M.ENUM = {
  "BLACK", "DARK_BLUE", "DARK_GREEN", "DARK_AQUA", "DARK_RED", "PURPLE",
  "ORANGE", "GRAY", "DARK_GRAY", "INDIGO", "BRIGHT_GREEN", "AQUA", "RED",
  "PINK", "YELLOW", "WHITE", "BROWN", "BRIGHT_PINK",
}

local function canonical(value)
  if type(value) ~= "string" or value == "" then return nil end
  for _, constant in ipairs(M.ENUM) do
    if value:upper() == constant then return constant end
  end
  return nil
end

-- opts.public = false  -> Sicherheit nicht oeffentlich (setzen scheitert)
-- opts.ignore_set = true -> nimmt den Aufruf an, aendert aber nichts
--                           (fuer die Rueckleseprobe)
function M.new(opts)
  opts = opts or {}
  local self = {
    color = opts.color,  -- Konstantenname oder nil
    public = opts.public ~= false,
    ignore_set = opts.ignore_set == true,
    calls = {},
  }

  local function require_public()
    if not self.public then
      error("This method requires the security mode to be public (security)", 0)
    end
  end

  function self.call(method, ...)
    local args = { ... }
    self.calls[#self.calls + 1] = { method = method, args = args }
    if method == "setDefaultColor" then
      require_public()
      local c = canonical(args[1])
      if not c then
        error("bad argument #1 (Invalid EnumColor '" .. tostring(args[1]) .. "')", 0)
      end
      if not self.ignore_set then self.color = c end
      return
    elseif method == "clearDefaultColor" then
      require_public()
      if not self.ignore_set then self.color = nil end
      return
    elseif method == "getDefaultColor" then
      return self.color
    end
    error("unexpected sorter call: " .. tostring(method), 0)
  end

  -- Nur die erfolgreich gesetzten Farben, in Reihenfolge.
  function self.applied()
    local out = {}
    for _, c in ipairs(self.calls) do
      if c.method == "setDefaultColor" then out[#out + 1] = canonical(c.args[1]) or "?" end
      if c.method == "clearDefaultColor" then out[#out + 1] = "NONE" end
    end
    return out
  end

  return self
end

return M
