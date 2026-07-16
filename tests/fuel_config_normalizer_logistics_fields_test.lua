-- Funktionaler Verifikationstest fuer FUEL-P0 (siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md Abschnitt 6): nodes/fuel/config_
-- normalizer.lua stuerzte bisher bei einer frischen oder teilweisen Config
-- ab, weil logistics.destinations (und sources/routes) nie normalisiert
-- wurden, bevor "for i, dest in ipairs(lg.destinations) do" lief. Laedt das
-- echte Modul und die echte FUEL-Defaultconfig und prueft alle im Audit
-- geforderten Pflicht-Faelle: leere Config, aktuelle Defaultconfig,
-- logistics={}, ungueltige logistics-Typen.

local REPO = os.getenv("REPO_ROOT") or "."
if type(package) == "table" and type(package.path) == "string" then
  package.path = REPO .. "/xreactor/?.lua;" .. REPO .. "/xreactor/?/init.lua;" .. package.path
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local utils = require("core.utils")
local normalizer = require("nodes.fuel.config_normalizer")
local fuel_config = require("nodes.fuel.config")

local function add_warning_noop() end

-- nodes/fuel/config.lua (the shipped default config) has no top-level
-- "channels" field -- that's supplied separately by nodes/fuel/main.lua's
-- own local DEFAULT_CONFIG table in production. non_rt_config.apply_common()
-- (called before the logistics normalization this test targets) requires
-- defaults.channels.control/.status to exist, so build a "defaults" object
-- that matches the real production shape without duplicating all of
-- main.lua's DEFAULT_CONFIG.
local function make_defaults()
  local defaults = utils.deep_copy(fuel_config)
  defaults.channels = { control = 6501, status = 6502 }
  return defaults
end

------------------------------------------------------------------------------
-- Fall 1: komplett leere Config (frische Installation).
------------------------------------------------------------------------------

do
  local config_values = {}
  local ok, err = pcall(normalizer.normalize, config_values, make_defaults(), add_warning_noop, utils)
  check(ok, "normalize() must not crash on a completely empty config (got: " .. tostring(err) .. ")")
  if ok then
    check(type(config_values.logistics) == "table", "logistics must be a table after normalize")
    check(type(config_values.logistics.destinations) == "table", "logistics.destinations must be normalized to a table")
    check(type(config_values.logistics.sources) == "table", "logistics.sources must be normalized to a table")
    check(type(config_values.logistics.routes) == "table", "logistics.routes must be normalized to a table")
  end
end

------------------------------------------------------------------------------
-- Fall 2: die echte, ausgelieferte FUEL-Defaultconfig als Benutzerconfig.
------------------------------------------------------------------------------

do
  local config_values = utils.deep_copy(fuel_config)
  local ok, err = pcall(normalizer.normalize, config_values, make_defaults(), add_warning_noop, utils)
  check(ok, "normalize() must not crash on the shipped default config (got: " .. tostring(err) .. ")")
  if ok then
    check(type(config_values.logistics.destinations) == "table", "destinations must be a table for the default config")
  end
end

------------------------------------------------------------------------------
-- Fall 3: logistics = {} (Nutzer hat den Block absichtlich geleert).
------------------------------------------------------------------------------

do
  local config_values = { logistics = {} }
  local ok, err = pcall(normalizer.normalize, config_values, make_defaults(), add_warning_noop, utils)
  check(ok, "normalize() must not crash with logistics={} (got: " .. tostring(err) .. ")")
  if ok then
    check(type(config_values.logistics.destinations) == "table", "destinations must be normalized when logistics={}")
    check(type(config_values.logistics.sources) == "table", "sources must be normalized when logistics={}")
    check(type(config_values.logistics.routes) == "table", "routes must be normalized when logistics={}")
    check(#config_values.logistics.destinations == 0, "destinations must be empty, not pre-populated")
  end
end

------------------------------------------------------------------------------
-- Fall 4: ungueltige Typen fuer die logistics-Unterfelder.
------------------------------------------------------------------------------

do
  local config_values = { logistics = { destinations = "not-a-table", sources = 42, routes = false } }
  local ok, err = pcall(normalizer.normalize, config_values, make_defaults(), add_warning_noop, utils)
  check(ok, "normalize() must not crash with invalid logistics field types (got: " .. tostring(err) .. ")")
  if ok then
    check(type(config_values.logistics.destinations) == "table", "invalid destinations value must be replaced with a table")
    check(type(config_values.logistics.sources) == "table", "invalid sources value must be replaced with a table")
    check(type(config_values.logistics.routes) == "table", "invalid routes value must be replaced with a table")
  end
end

------------------------------------------------------------------------------
-- Der urspruengliche Crash-Repro: ipairs(lg.destinations) direkt nachstellen.
------------------------------------------------------------------------------

do
  local config_values = {}
  normalizer.normalize(config_values, make_defaults(), add_warning_noop, utils)
  local ok, err = pcall(function()
    for _ in ipairs(config_values.logistics.destinations) do end
  end)
  check(ok, "ipairs(logistics.destinations) must not raise after normalize() (got: " .. tostring(err) .. ")")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
