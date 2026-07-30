local non_rt_config = require("core.non_rt_config")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if config_values.storage_bus ~= nil and type(config_values.storage_bus) ~= "string" then
    config_values.storage_bus = defaults.storage_bus
    add_warning("storage_bus invalid; defaulting to " .. tostring(defaults.storage_bus))
  end
  if config_values.minimum_reserve == nil and type(config_values.target) == "number" then
    config_values.minimum_reserve = config_values.target
    add_warning("minimum_reserve missing; using target value " .. tostring(config_values.target))
  end
  if type(config_values.minimum_reserve) ~= "number" or config_values.minimum_reserve < 0 then
    config_values.minimum_reserve = defaults.minimum_reserve
    add_warning("minimum_reserve missing/invalid; defaulting to " .. tostring(defaults.minimum_reserve))
  end
  if type(config_values.target) ~= "number" or config_values.target < 0 then
    config_values.target = defaults.target
    add_warning("target missing/invalid; defaulting to " .. tostring(defaults.target))
  end

  -- Normalize logistics config block.
  if config_values.logistics == nil then
    config_values.logistics = utils.deep_copy and utils.deep_copy(defaults.logistics)
      or { enabled = false, interval = 10, discovery_interval = 60,
           max_per_cycle = 64, sources = {}, destinations = {}, routes = {} }
  end
  local lg = config_values.logistics
  if type(lg) ~= "table" then
    lg = {}
    config_values.logistics = lg
    add_warning("logistics config invalid; using defaults")
  end
  -- enabled must be explicit boolean true to activate
  if lg.enabled ~= true then lg.enabled = false end
  if type(lg.interval) ~= "number" or lg.interval <= 0 then
    lg.interval = (defaults.logistics and defaults.logistics.interval) or 10
  end
  if type(lg.discovery_interval) ~= "number" or lg.discovery_interval <= 0 then
    lg.discovery_interval = (defaults.logistics and defaults.logistics.discovery_interval) or 60
  end
  if type(lg.max_per_cycle) ~= "number" or lg.max_per_cycle <= 0 then
    lg.max_per_cycle = (defaults.logistics and defaults.logistics.max_per_cycle) or 64
  end
  if type(lg.reactors)      ~= "table" then lg.reactors      = {} end
  if type(lg.waste)         ~= "table" then lg.waste         = {} end
  if type(lg.redstone_tree) ~= "table" then lg.redstone_tree = {} end
  if type(lg.valve_open_ms) ~= "number" or lg.valve_open_ms <= 0 then
    lg.valve_open_ms = (defaults.logistics and defaults.logistics.valve_open_ms) or 2000
  end
  -- Fix (2026-07-16): CRITICAL (FUEL-P0, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md). destinations/sources/routes wurden bisher
  -- NIE normalisiert -- weder DEFAULT_LOGISTICS noch eine leere
  -- "logistics={}"-Benutzerconfig enthalten ein "destinations"-Feld. Der
  -- Destination-Validierungsloop weiter unten ruft aber unbedingt
  -- ipairs(lg.destinations) auf, was bei einer frischen oder teilweisen
  -- Config sofort mit "bad argument #1 to 'ipairs' (table expected, got
  -- nil)" abstuerzte, noch bevor die Node betriebsbereit war.
  if type(lg.destinations) ~= "table" then lg.destinations = {} end
  if type(lg.sources)      ~= "table" then lg.sources      = {} end
  if type(lg.routes)       ~= "table" then lg.routes       = {} end
  -- Fix (2026-07-09): kein Hinweis existierte bisher, wenn Reaktoren
  -- konfiguriert sind, "enabled" aber noch false ist -- ein leicht zu
  -- uebersehender Zustand, in dem alle Reaktor-Eintraege fehlerfrei
  -- validieren, aber M:tick() trotzdem sofort zurueckkehrt (keine
  -- Belieferung passiert), ohne dass irgendwo eine Meldung erscheint.
  if lg.enabled == false and #lg.reactors > 0 then
    add_warning(string.format(
      "logistics.enabled=false trotz %d konfigurierter Reaktoren — es wird KEIN Fuel exportiert, bis enabled=true gesetzt wird",
      #lg.reactors))
  end
  if type(lg.me_bridge)    ~= "string" then
    lg.me_bridge = (defaults.logistics and defaults.logistics.me_bridge) or "me_bridge"
  end
  if type(lg.interval) ~= "number" or lg.interval <= 0 then
    lg.interval = (defaults.logistics and defaults.logistics.interval) or 5
  end
  -- Validate each reactor entry
  for i, r in ipairs(lg.reactors) do
    if not r.inlet then
      add_warning(string.format("logistics.reactors[%d] missing inlet peripheral", i))
    end
    if not r.item then
      add_warning(string.format("logistics.reactors[%d] missing item name", i))
    end
    if r.request_below and (tonumber(r.request_below) or 0) > 1.0 then
      add_warning(string.format(
        "logistics.reactors[%d].request_below=%s should be 0.0-1.0 (ratio, not %%)",
        i, tostring(r.request_below)))
    end
  end
  -- Validate destination tags
  local valid_tags = { reactor_injector = true, reprocessor = true, fuel_storage = true, me = true, reactor_output = true, generic = true }
  for i, dest in ipairs(lg.destinations) do
    if type(dest) == "table" and dest.tag and not valid_tags[dest.tag] then
      add_warning(string.format(
        "logistics.destinations[%d].tag '%s' unknown; valid: reactor_injector, reprocessor, generic",
        i, tostring(dest.tag)
      ))
    end
  end
end

return M
