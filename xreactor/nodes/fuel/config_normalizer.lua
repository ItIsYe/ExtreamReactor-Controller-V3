local non_rt_config = require("core.non_rt_config")

local M = {}

local function nonempty_string(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  local ui_scale = tonumber(config_values.ui_scale)
  if ui_scale ~= 0.5 and ui_scale ~= 1.0 then
    config_values.ui_scale = tonumber(defaults.ui_scale) or 1.0
    add_warning("ui_scale invalid; supported values are 1.0 and 0.5; defaulting to "
      .. tostring(config_values.ui_scale))
  else
    config_values.ui_scale = ui_scale
  end

  if config_values.storage_bus ~= nil and type(config_values.storage_bus) ~= "string" then
    config_values.storage_bus = defaults.storage_bus
    add_warning("storage_bus invalid; defaulting to " .. tostring(defaults.storage_bus))
  end
  if config_values.reserve_items ~= nil and type(config_values.reserve_items) ~= "table" then
    config_values.reserve_items = defaults.reserve_items
    add_warning("reserve_items invalid; defaulting to shipped item list")
  elseif type(config_values.reserve_items) == "table" then
    local cleaned = {}
    for i, entry in ipairs(config_values.reserve_items) do
      if type(entry) == "table" and nonempty_string(entry.item) then
        cleaned[#cleaned + 1] = entry
      else
        add_warning(string.format("reserve_items[%d] invalid; ignoring", i))
      end
    end
    config_values.reserve_items = cleaned
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
  if type(lg.reactors) ~= "table" then lg.reactors = {} end
  if type(lg.waste) ~= "table" then lg.waste = {} end
  if type(lg.redstone_tree) ~= "table" then lg.redstone_tree = {} end
  if type(lg.valve_open_ms) ~= "number" or lg.valve_open_ms <= 0 then
    lg.valve_open_ms = (defaults.logistics and defaults.logistics.valve_open_ms) or 2000
  end
  if type(lg.destinations) ~= "table" then lg.destinations = {} end
  if type(lg.sources) ~= "table" then lg.sources = {} end
  if type(lg.routes) ~= "table" then lg.routes = {} end
  if type(lg.me_bridge) ~= "string" then
    lg.me_bridge = (defaults.logistics and defaults.logistics.me_bridge) or "me_bridge"
  end
  if lg.export_chest ~= nil and not nonempty_string(lg.export_chest) then
    lg.export_chest = nil
    add_warning("logistics.export_chest invalid; ignoring")
  end

  -- A configured reactor is an actuator route. Invalid demand identity or
  -- amounts must disable logistics as a whole instead of falling into the
  -- historical "always supply" path. Keep the original entries in memory so
  -- UI/config editors can still show and repair them; only runtime activation
  -- is fail-closed.
  -- Zwei getrennte Begriffe, frueher einer:
  --
  --   global_block      -- eine Voraussetzung fuer JEDE Lieferung fehlt
  --                        (der gemeinsame Uebergabepunkt). Dann ist
  --                        wirklich nichts moeglich.
  --   r.disabled_reason -- DIESER Eintrag taugt nicht. Er wird
  --                        uebersprungen, die uebrigen laufen weiter.
  --
  -- Vorher war beides dasselbe Flag: ein einziger unbrauchbarer Eintrag --
  -- etwa ein Reaktor, dessen Identitaet nie gelernt wurde und der deshalb
  -- kein reactor_id hat -- legte die Belieferung ALLER Reaktoren still.
  -- Auf einer Anlage mit vielen konfigurierten und wenigen laufenden
  -- Reaktoren ist das der Normalfall, nicht der Ausnahmefall, und es war
  -- an nichts abzulesen.
  local global_block = false

  -- export_chest ist der EINE geteilte Uebergabepunkt jeder Lieferung
  -- (siehe logistics_router.lua) -- eine globale Voraussetzung, kein Feld
  -- je Reaktor, deshalb hier einmal geprueft.
  if #lg.reactors > 0 and not nonempty_string(lg.export_chest) then
    add_warning("logistics.export_chest missing; unsafe/unconfigured export target, logistics will be disabled until set")
    global_block = true
  end

  for i, r in ipairs(lg.reactors) do
    if type(r) ~= "table" then
      -- Kein Tabellen-Eintrag: hier laesst sich nicht einmal ein Grund
      -- hinterlegen. logistics_router ueberspringt ihn ohnehin.
      add_warning(string.format("logistics.reactors[%d] invalid entry", i))
    else
      -- Ersten Grund behalten: der erste Fehler ist der aussagekraeftigste,
      -- Folgefehler sind oft nur seine Auswirkung.
      local function disable(reason)
        add_warning(reason)
        r.disabled_reason = r.disabled_reason or reason
      end

      local reactor_id = r.reactor_id or r.reactor_port -- legacy alias
      if not nonempty_string(reactor_id) then
        disable(string.format(
          "logistics.reactors[%d] (%s) ohne reactor_id -- Eintrag stillgelegt,"
            .. " die Identitaet lernt der Knoten aus der RT-Statusmeldung",
          i, tostring(r.name or r.label or "?")))
      end
      if r.path ~= nil and type(r.path) ~= "table" then
        disable(string.format(
          "logistics.reactors[%d].path ungueltig; erwartet eine Liste von VALVE-Node-Ids -- Eintrag stillgelegt", i))
      end
      if r.request_below ~= nil then
        local threshold = tonumber(r.request_below)
        if threshold == nil or threshold < 0 or threshold > 1 then
          disable(string.format(
            "logistics.reactors[%d].request_below=%s ungueltig; erwartet 0.0-1.0 -- Eintrag stillgelegt",
            i, tostring(r.request_below)))
        end
      end
      if r.fill_amount ~= nil then
        local amount = tonumber(r.fill_amount)
        if amount == nil or amount <= 0 then
          disable(string.format(
            "logistics.reactors[%d].fill_amount=%s ungueltig; muss > 0 sein -- Eintrag stillgelegt",
            i, tostring(r.fill_amount)))
        end
      end
      if r.min_in_me ~= nil then
        local reserve = tonumber(r.min_in_me)
        if reserve == nil or reserve < 0 then
          disable(string.format(
            "logistics.reactors[%d].min_in_me=%s ungueltig; muss >= 0 sein -- Eintrag stillgelegt",
            i, tostring(r.min_in_me)))
        end
      end
      if r.resupply_cooldown_s ~= nil then
        local cooldown = tonumber(r.resupply_cooldown_s)
        if cooldown == nil or cooldown < 0 then
          disable(string.format(
            "logistics.reactors[%d].resupply_cooldown_s=%s ungueltig; muss >= 0 sein -- Eintrag stillgelegt",
            i, tostring(r.resupply_cooldown_s)))
        end
      end
    end
  end

  local disabled_entries = 0
  for _, r in ipairs(lg.reactors) do
    if type(r) == "table" and r.disabled_reason then disabled_entries = disabled_entries + 1 end
  end
  if disabled_entries > 0 then
    add_warning(string.format(
      "%d von %d Reaktor-Eintraegen stillgelegt -- die uebrigen werden weiter beliefert",
      disabled_entries, #lg.reactors))
  end

  if global_block and lg.enabled then
    lg.enabled = false
    add_warning("logistics disabled: der gemeinsame Uebergabepunkt (logistics.export_chest)"
      .. " fehlt -- ohne ihn ist ueberhaupt keine Lieferung moeglich")
  elseif lg.enabled == false and #lg.reactors > 0 then
    add_warning(string.format(
      "logistics.enabled=false despite %d configured reactors; no fuel will be exported",
      #lg.reactors))
  end

  local valid_tags = {
    reactor_injector = true, reprocessor = true, fuel_storage = true,
    me = true, reactor_output = true, generic = true
  }
  for i, dest in ipairs(lg.destinations) do
    if type(dest) == "table" and dest.tag and not valid_tags[dest.tag] then
      add_warning(string.format(
        "logistics.destinations[%d].tag '%s' unknown; valid: reactor_injector, reprocessor, fuel_storage, me, reactor_output, generic",
        i, tostring(dest.tag)))
    end
  end
end

return M
