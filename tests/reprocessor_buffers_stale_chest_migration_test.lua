-- Regression coverage: config.buffers is legacy state from before the
-- SORTER-KISTE rework (2026-09-17) -- an operator who used the old PUFFER
-- UI has the Sorter-Kiste (or ZUSATZ-KISTE) name persisted there. main.lua's
-- discover() excludes both from ever being (re-)registered as a "buffer"
-- (Reprocessor-Maschine) device, but without cleaning up the stale entry
-- itself, real-world reports show it can still show up as an "unsupported"
-- Verarbeitungslinie/MASCHINE on the Overview page (a plain chest never has
-- process()). main.lua must therefore migrate config.buffers once at boot,
-- stripping any entry matching config.feed.sorter_chest or config.feed.
-- chest.target, and persist the cleaned list.
--
-- main.lua has heavy boot-time side effects and cannot be require()'d
-- directly (see other tests in this suite), so this is a structural check
-- on the actual source, matching the established pattern for this file.

local function read(p)
  local f = assert(io.open(p, 'r'), 'cannot open ' .. p)
  local c = f:read('*a')
  f:close()
  return c
end

local repo_root = os.getenv('REPO_ROOT') or '.'
local main_src = read(repo_root .. '/xreactor/nodes/reprocessor/main.lua')

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

assert_true(main_src:find('name == fd%.sorter_chest', 1) ~= nil,
  'main.lua must strip config.buffers entries matching config.feed.sorter_chest at boot')
assert_true(main_src:find('name == chest_target', 1) ~= nil,
  'main.lua must strip config.buffers entries matching config.feed.chest.target at boot')
assert_true(main_src:find('config%.buffers = cleaned', 1) ~= nil,
  'main.lua must actually replace config.buffers with the cleaned list')

-- The migration must run AFTER config_normalizer.normalize() (so
-- fd.sorter_chest/fd.chest.target are already validated) and persist the
-- cleanup via utils.write_config, not just mutate the in-memory table.
local normalize_pos = main_src:find('config_normalizer%.normalize%(config, DEFAULT_CONFIG', 1)
local cleaned_pos = main_src:find('config%.buffers = cleaned', 1)
assert_true(normalize_pos ~= nil and cleaned_pos ~= nil and cleaned_pos > normalize_pos,
  'the config.buffers migration must run after config_normalizer.normalize()')

local write_pos = main_src:find('utils%.write_config%(CONFIG%.CONFIG_PATH, config%)', cleaned_pos)
assert_true(write_pos ~= nil and write_pos > cleaned_pos,
  'the cleaned config.buffers must be persisted via utils.write_config after being cleaned')

print('reprocessor_buffers_stale_chest_migration_test.lua: ok')
