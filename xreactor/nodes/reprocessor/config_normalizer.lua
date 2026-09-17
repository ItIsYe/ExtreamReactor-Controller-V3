local non_rt_config = require("core.non_rt_config")
local logistical_sorter = require("adapters.logistical_sorter")

local M = {}

function M.normalize(config_values, defaults, add_warning, utils)
  non_rt_config.apply_common(config_values, defaults, add_warning, utils)

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
  if type(fd.sorter) ~= "string" or fd.sorter == "" then fd.sorter = nil end
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

  -- sorter_chest (die SORTER-KISTE) ist das tatsaechliche ME-Bridge-
  -- Exportziel (siehe feed_router.lua) -- genau wie FUEL's logistics.
  -- export_chest (siehe nodes/fuel/config_normalizer.lua) muss ein
  -- fehlendes Exportziel laut und deutlich gewarnt werden, statt sich
  -- hinter einem Platzhalter-Default zu verstecken.
  if type(fd.sorter_chest) ~= "string" or fd.sorter_chest == "" then fd.sorter_chest = nil end
  if #fd.targets > 0 and fd.sorter_chest == nil then
    add_warning("feed.sorter_chest (SORTER-KISTE) fehlt; Feeding bleibt wirkungslos bis im Router-UI eine Sorter-Kiste gewaehlt wurde")
  end
  if #fd.targets > 0 and fd.sorter == nil then
    add_warning("feed.sorter fehlt; Feeding bleibt wirkungslos bis im Router-UI ein Logistical Sorter gewaehlt wurde")
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
end

return M
