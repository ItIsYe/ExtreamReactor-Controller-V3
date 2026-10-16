-- nodes/valve/hop_reporter.lua
-- Optional, purely passive sensor: wraps a locally wired inventory
-- peripheral (a junction chest this VALVE-Node happens to sit next to,
-- connected via its own Wired Modem -- separate from the existing Wireless
-- Modem used for SET_VALVE/VALVE_ACK) and reports its contents so FUEL's
-- nodes/fuel/hop_timing.lua can learn how long fuel actually takes to reach
-- each hop. Disabled (M:is_enabled() == false) unless config.hop_chest
-- names a peripheral that was actually present and wrappable at boot --
-- this module never controls anything and never blocks/opens a valve; a
-- missing/misconfigured chest just means no HOP_SCAN is ever sent, nothing
-- else changes.

local M = {}
M.__index = M

-- Auto-Erkennung NUR wenn eindeutig: liefert den Namen zurueck, wenn genau
-- EINE Peripherie (ausser den ausgeschlossenen Namen -- Sorter, Wireless
-- Modem) eine list()-Methode hat (= eine Kiste/Inventory). Bei 0 oder
-- mehreren Kandidaten wird nil zurueckgegeben (plus die volle Kandidaten-
-- liste zum Loggen) -- bewusst kein Raten bei Mehrdeutigkeit, das war
-- genau das Risiko, das die bisherige "MUSS explizit gesetzt werden"-
-- Regel vermeiden sollte (siehe Kopfkommentar). Rein lesend: wrapt nur zum
-- Pruefen von .list, aendert nichts an der Peripherie.
function M.autodetect_chest_name(peripheral_api, exclude_names)
  local excluded = {}
  for _, name in ipairs(exclude_names or {}) do
    if type(name) == "string" then excluded[name] = true end
  end
  if not peripheral_api or type(peripheral_api.getNames) ~= "function" then
    return nil, {}
  end
  local ok_names, names = pcall(peripheral_api.getNames)
  if not ok_names or type(names) ~= "table" then return nil, {} end

  local candidates = {}
  for _, name in ipairs(names) do
    if not excluded[name] then
      local wrap_ok, wrapped = pcall(peripheral_api.wrap, name)
      if wrap_ok and wrapped and type(wrapped.list) == "function" then
        candidates[#candidates + 1] = name
      end
    end
  end
  if #candidates == 1 then return candidates[1], candidates end
  return nil, candidates
end

function M.new(opts)
  opts = opts or {}
  local peripheral_api = opts.peripheral_api or peripheral
  local self = setmetatable({
    peripheral = peripheral_api,
    chest = nil,
    chest_name = nil,
  }, M)

  local configured = type(opts.hop_chest) == "string" and opts.hop_chest ~= "" and opts.hop_chest or nil
  if configured then
    local present_ok, present = pcall(peripheral_api.isPresent, configured)
    if present_ok and present then
      local wrap_ok, wrapped = pcall(peripheral_api.wrap, configured)
      if wrap_ok and wrapped and type(wrapped.list) == "function" then
        self.chest = wrapped
        self.chest_name = configured
      end
    end
  end
  return self
end

function M:is_enabled()
  return self.chest ~= nil
end

-- Aggregates the chest's slots into { [item_name] = total_count }. nil on
-- any failure (chest removed/network hiccup) -- caller simply skips sending
-- a report that tick, same as any other best-effort telemetry read.
function M:scan()
  if not self.chest then return nil end
  local ok, slots = pcall(self.chest.list)
  if not ok or type(slots) ~= "table" then return nil end
  local counts = {}
  for _, entry in pairs(slots) do
    if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
      counts[entry.name] = (counts[entry.name] or 0) + (tonumber(entry.count) or 0)
    end
  end
  return counts
end

return M
