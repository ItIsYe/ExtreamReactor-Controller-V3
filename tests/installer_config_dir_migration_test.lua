-- tests/installer_config_dir_migration_test.lua
--
-- Regression test: config moved from /xreactor/config (inside the tree the
-- installer deletes+recreates on every reinstall -- the actual cause of a
-- real reactor-naming data loss) to /xreactor_config (a sibling directory,
-- like /xreactor_logs/_recovery, never touched by that delete). Without a
-- migration step, an already-deployed node's very next auto-update would
-- find no role.lua/config at all under the new path and hard-fail with
-- "role.lua fehlt" instead of quietly carrying its config forward.
--
-- installer/init.lua is `return function(deps) ... end` and runs a lot of
-- top-level work immediately (see installer_journal_ordering_and_release_
-- last_test.lua's own note on this) -- the migration block is extracted
-- via markers and run in isolation, same technique as
-- installer_init_critical_write_abort_test.lua.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function extract(src, start_marker, end_marker)
  local start_idx = assert(src:find(start_marker, 1, true), "start marker not found: " .. start_marker)
  local end_idx = assert(src:find(end_marker, start_idx, true), "end marker not found: " .. end_marker)
  return src:sub(start_idx, end_idx - 1)
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read_file(repo_root .. "/xreactor/installer/init.lua")
local snippet = "local CONFIG_DIR = \"/xreactor_config\"\n"
  .. extract(src, "-- One-time migration", "-- Rolle bestimmen")

local function run_snippet(fs_impl, p_fn)
  _G.fs = fs_impl
  _G.p = p_fn or function() end
  local chunk, lerr = load(snippet, "=migration_snippet", "t")
  if not chunk then error("snippet failed to parse: " .. tostring(lerr) .. "\n---\n" .. snippet) end
  return pcall(chunk)
end

-- Case 1: node still on the old path -- must be moved to the new one.
do
  local state = { ["/xreactor/config"] = true }
  local moved = {}
  local fs_impl = {
    exists = function(p) return state[p] == true end,
    move = function(from, to)
      moved[#moved + 1] = { from = from, to = to }
      state[from] = nil
      state[to] = true
    end,
  }
  local ok, err = run_snippet(fs_impl)
  if not ok then error("migration must not fail for a genuine old-path node: " .. tostring(err)) end
  if #moved ~= 1 or moved[1].from ~= "/xreactor/config" or moved[1].to ~= "/xreactor_config" then
    error("expected exactly one move /xreactor/config -> /xreactor_config, got: " .. textutils.serialize(moved))
  end
  if not state["/xreactor_config"] or state["/xreactor/config"] then
    error("expected the old path gone and the new path present after migration")
  end
end

-- Case 2: already migrated (new path exists) -- must be a complete no-op,
-- even if a stale old path somehow still exists.
do
  local state = { ["/xreactor_config"] = true, ["/xreactor/config"] = true }
  local move_calls = 0
  local fs_impl = {
    exists = function(p) return state[p] == true end,
    move = function() move_calls = move_calls + 1 end,
  }
  local ok, err = run_snippet(fs_impl)
  if not ok then error("no-op case must not fail: " .. tostring(err)) end
  if move_calls ~= 0 then
    error("expected zero fs.move() calls once CONFIG_DIR already exists, got " .. move_calls)
  end
end

-- Case 3: genuinely fresh node (neither path exists) -- no-op, no error.
do
  local state = {}
  local move_calls = 0
  local fs_impl = {
    exists = function(p) return state[p] == true end,
    move = function() move_calls = move_calls + 1 end,
  }
  local ok, err = run_snippet(fs_impl)
  if not ok then error("fresh-node case must not fail: " .. tostring(err)) end
  if move_calls ~= 0 then
    error("expected zero fs.move() calls on a genuinely fresh node, got " .. move_calls)
  end
end

-- Case 4: the move itself fails -- must abort loudly, not silently
-- continue with no config at either location.
do
  local state = { ["/xreactor/config"] = true }
  local fs_impl = {
    exists = function(p) return state[p] == true end,
    move = function() error("simulated move failure") end,
  }
  local ok, err = run_snippet(fs_impl)
  if ok then
    error("CRITICAL: a failed config migration must abort, not silently continue")
  end
  if not tostring(err):find("Config%-Migration fehlgeschlagen") then
    error("expected a migration-failure abort error, got: " .. tostring(err))
  end
end

print("installer_config_dir_migration_test.lua: ok")
