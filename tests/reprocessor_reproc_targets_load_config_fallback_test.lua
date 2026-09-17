package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test. Log evidence (2026-09-17, xreactor_logs/reproc/node-100.
-- log): "reproc_targets.lua konnte nicht geladen werden, Ziele bleiben
-- leer: ...reproc_targets.lua:1: unexpected symbol near '{'" -- on every
-- single boot, despite the file on disk (confirmed via a full disk dump)
-- being a perfectly well-formed, previously-saved 9-target configuration.
-- User report: "eigentlich hatte ich routen eingerichtet" (had routes
-- configured) -- they were silently lost on every reboot, including an
-- auto-update reboot.
--
-- Root cause: nodes/reprocessor/main.lua loaded /xreactor_config/
-- reproc_targets.lua with a raw "pcall(dofile, targets_path)". But
-- color_router_ui.lua's _save() persists that file via core/utils.lua's
-- write_config(), which serializes with textutils.serialize() -- CC:
-- Tweaked's real serializer produces a bare "{ ... }" table-literal
-- string, deliberately with NO "return" statement in front (matching
-- what textutils.unserialize() expects back). A bare "{...}" is not a
-- valid standalone Lua chunk/statement ("unexpected symbol near '{'"),
-- so dofile() on it fails to parse EVERY TIME, unconditionally -- this
-- was never a transient/corruption issue, the file could never have
-- loaded successfully via dofile() in its written form.
--
-- Fix: use utils.load_config() instead, exactly like every other
-- persisted config file in this codebase -- it already tries load() as
-- Lua first and falls back to textutils.unserialize() for exactly this
-- bare-serialized shape.
--
-- nodes/reprocessor/main.lua has heavy boot-time side effects and cannot
-- be require()'d directly, so this drives the actual save/load pair
-- (color_router_ui.lua's real _save(), core/utils.lua's real write_config/
-- load_config) standalone, proving the full round-trip that main.lua's
-- boot sequence depends on.

local utils = require('core.utils')
local color_router_ui = require('nodes.reprocessor.color_router_ui')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ' expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(v, msg) if not v then error(msg or 'assert_true failed') end end

-- In-memory fake filesystem, just enough for write_config()/load_config().
local files = {}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function(p) return p:match('^(.*)/[^/]+$') or '' end,
  makeDir = function(p) files[p] = files[p] or '<dir>' end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst)
    if files[src] == nil then error('missing source ' .. tostring(src), 0) end
    files[dst] = files[src]; files[src] = nil
  end,
  open = function(p, mode)
    if mode == 'w' then
      local buffer = ''
      return { write = function(v) buffer = buffer .. tostring(v) end, close = function() files[p] = buffer end }
    elseif mode == 'r' then
      if files[p] == nil or files[p] == '<dir>' then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.peripheral = { isPresent = function() return true end, getNames = function() return {} end,
  getType = function() return nil end, getMethods = function() return {} end }

local path = '/xreactor_config/reproc_targets.lua'

-- 1) Save a realistic multi-target config through the REAL Router UI save
--    path, exactly like the operator did in-game.
local config = { feed = { sorter = nil, targets = {} } }
local ui = color_router_ui.new({ config = config, write_config = utils.write_config, config_path = path, log = function() end })
ui.sorter_name = 'logistical_sorter_0'
ui.chest_enabled = true
ui.chest_target = 'minecraft:chest_9'
ui.targets = {
  { label = 'Reprocessor 1', color = 'GREEN' },
  { label = 'Reprocessor 2', color = 'CYAN' },
}
assert_true(ui:_save(), 'save must succeed')
assert_true(files[path] ~= nil, 'the file must actually be written')

-- Sanity: the persisted content is a bare table literal with NO leading
-- "return" -- this is the exact shape that broke dofile().
local trimmed = files[path]:gsub('^%s+', '')
assert_true(trimmed:sub(1, 1) == '{', 'sanity: write_config() must persist a bare "{...}" literal (no "return")')
assert_true(not trimmed:match('^return'), 'sanity: write_config() output must not start with "return"')

-- 2) A raw dofile() on that exact file (the OLD, broken loading method)
--    must fail -- proves the bug is real and reproducible, not
--    hypothetical.
local native_dofile = dofile
_G.dofile = function(p)
  if files[p] ~= nil then
    local loader, lerr = load(files[p], '=' .. p, 't', {})
    if not loader then error(lerr, 0) end
    return loader()
  end
  return native_dofile(p)
end
local dofile_ok, dofile_err = pcall(dofile, path)
_G.dofile = native_dofile
assert_true(not dofile_ok, 'raw dofile() on a write_config()-persisted file must fail to parse (this was the actual production bug)')
assert_true(tostring(dofile_err):find('unexpected symbol', 1, true) ~= nil,
  'the dofile() failure must be the exact "unexpected symbol near \'{\'" parse error seen in the real log, got: ' .. tostring(dofile_err))

-- 3) utils.load_config() (the FIX: what main.lua now uses instead) must
--    successfully load the very same file.
local loaded, meta = utils.load_config(path, {})
assert_true(meta.source ~= 'defaults', 'load_config() must not silently fall back to empty defaults for a real, well-formed file')
assert_eq(#loaded.targets, 2, 'both targets must survive the round-trip through the real save path')
assert_eq(loaded.targets[1].color, 'GREEN')
assert_eq(loaded.targets[2].color, 'CYAN')
assert_eq(loaded.sorter, 'logistical_sorter_0')
assert_eq(loaded.chest.target, 'minecraft:chest_9')

-- 4) Structural check on the actual boot-time wiring: main.lua must call
--    utils.load_config() for reproc_targets.lua, and must NOT call dofile
--    on it (regression guard against reverting to the broken loader).
local function read(p)
  local f = assert(io.open(p, 'r'), 'cannot open ' .. p)
  local c = f:read('*a')
  f:close()
  return c
end
local repo_root = os.getenv('REPO_ROOT') or '.'
local main_src = read(repo_root .. '/xreactor/nodes/reprocessor/main.lua')
assert_true(main_src:find('utils%.load_config%(targets_path', 1) ~= nil,
  'main.lua must load reproc_targets.lua via utils.load_config(), not a raw dofile()')
assert_true(not main_src:find('pcall%(dofile, targets_path%)', 1, true),
  'main.lua must not call dofile() on reproc_targets.lua -- that is the exact bug this test guards against')

print('reprocessor_reproc_targets_load_config_fallback_test.lua: ok')
