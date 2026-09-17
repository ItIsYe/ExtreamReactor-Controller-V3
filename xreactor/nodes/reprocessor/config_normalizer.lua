local non_rt_config = require("core.non_rt_config")
local logistical_sorter = require("adapters.logistical_sorter")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

  if type(config_values.buffers) ~= "table" then
    config_values.buffers = utils.deep_copy(defaults.buffers)
    add_warning("buffers missing/invalid; defaulting to configured list")
  end

  -- Normalize feed config block (random-interval Cyanite supply to reprocessors).
  if config_values.feed == nil then
    config_values.feed = utils.deep_copy(defaults.feed) or {}
  end
  local fd = config_values.feed
  if type(fd) ~= "table" then
    fd = {}
    config_values.feed = fd
    add_warning("feed config invalid; using defaults")
  end
  local d = defaults.feed or {}
  if fd.enabled ~= true then fd.enabled = false end
  if type(fd.me_bridge) ~= "string" then
    fd.me_bridge = d.me_bridge or "me_bridge"
  end
  if type(fd.sorter) ~= "string" then
    fd.sorter = d.sorter or "logistical_sorter_0"
  end
  if type(fd.waste_item) ~= "string" then
    fd.waste_item = d.waste_item or "bigreactors:cyanite_ingot"
  end
  if type(fd.feed_amount) ~= "number" or fd.feed_amount <= 0 then
    fd.feed_amount = d.feed_amount or 2
  end
  if type(fd.interval_min_s) ~= "number" or fd.interval_min_s <= 0 then
    fd.interval_min_s = d.interval_min_s or 20
  end
  if type(fd.interval_max_s) ~= "number" or fd.interval_max_s < fd.interval_min_s then
    fd.interval_max_s = math.max(d.interval_max_s or 60, fd.interval_min_s)
  end
  if type(fd.discovery_interval) ~= "number" or fd.discovery_interval <= 0 then
    fd.discovery_interval = d.discovery_interval or 60
  end
  if type(fd.targets) ~= "table" then fd.targets = {} end

  -- buffers[1] ist seit dem PUFFER-Umbau (2026-09-17) das tatsaechliche
  -- ME-Bridge-Exportziel (siehe feed_router.lua), nicht mehr nur eine
  -- Kapazitaets-Anzeige. Genau wie FUEL's logistics.export_chest (siehe
  -- nodes/fuel/config_normalizer.lua) muss ein fehlendes Exportziel laut
  -- und deutlich gewarnt werden, statt sich hinter einem Platzhalter-
  -- Default zu verstecken, der wie eine echte Konfiguration aussieht.
  if #fd.targets > 0 and (type((config_values.buffers or {})[1]) ~= "string" or config_values.buffers[1] == "") then
    add_warning("buffers[1] (PUFFER-Exportziel) fehlt; Feeding bleibt deaktiviert bis im Router-UI eine Puffer-Kiste gewaehlt wurde")
  end

  for i, t in ipairs(fd.targets) do
    if not t.label then
      add_warning(string.format("feed.targets[%d] missing label", i))
    end
    if not logistical_sorter.is_valid_color(t.color) then
      -- A color saved under a since-removed legacy name (e.g. a config
      -- edition update tightened adapters/logistical_sorter.lua's COLORS
      -- to the confirmed-correct list) must be upgraded to its current
      -- replacement instead of the route silently breaking on the next
      -- boot -- an already-configured route must survive an update.
      local migrated = logistical_sorter.migrate_legacy_color(t.color)
      if migrated then
        add_warning(string.format("feed.targets[%d] (%s) color %s migrated to %s",
          i, tostring(t.label or "?"), tostring(t.color), migrated))
        t.color = migrated
      else
        add_warning(string.format("feed.targets[%d] (%s) invalid/missing color; feeding for this target will be skipped until fixed",
          i, tostring(t.label or "?")))
      end
    else
      t.color = t.color:upper()
    end
  end

  -- chest: optionale zweite Sammel-Kiste fuer rohes Cyanit, laeuft
  -- unabhaengig von der Reprocessor-Rotation, direkt per ME-Bridge/Wired-
  -- Modem-Export ohne Sorter/Farbe (siehe feed_router.lua).
  if type(fd.chest) ~= "table" then fd.chest = {} end
  if fd.chest.enabled ~= true then fd.chest.enabled = false end
  if fd.chest.enabled and (type(fd.chest.target) ~= "string" or fd.chest.target == "") then
    add_warning("feed.chest ist aktiviert, hat aber kein Ziel-Peripheral gesetzt; Befuellung der Kiste wird uebersprungen bis eines gesetzt ist")
  end
end

return M
