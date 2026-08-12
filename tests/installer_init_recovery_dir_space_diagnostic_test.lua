-- tests/installer_init_recovery_dir_space_diagnostic_test.lua
--
-- Regression test: installer/init.lua's fs.makeDir(RECOVERY_DIR) call runs
-- BEFORE /xreactor is deleted and BEFORE any stage_mod.write() call, so it
-- used to fail with a bare, un-actionable "out of space" (reported: node
-- freshly re-downloaded the installer, still failed with "Recovery-
-- Verzeichnis konnte nicht angelegt werden: ...: /xreactor_recovery: out
-- of space" and nothing else to go on). installer/init.lua now reports the
-- same free-space/needed-bytes/"check /xreactor_logs" diagnostic that
-- installer/stage.lua's M.write() already produces (see
-- installer_stage_space_diagnostic_test.lua) for this failure too.
--
-- init.lua is `return function(deps) ... end` and runs a lot of top-level
-- work immediately on invocation, which the rest of the suite avoids
-- driving fully (see installer_config_backup_fail_closed_test.lua's own
-- comment/approach) -- this checks the fix structurally against the real
-- source instead of executing the whole installer flow.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read_file(repo_root .. "/xreactor/installer/init.lua")

local function assert_contains(needle, label)
  if not src:find(needle, 1, true) then
    error(label .. ": expected marker not found: " .. needle)
  end
end

assert_contains('stage_mod.space_diagnostic(free, #serialized)',
  "recovery-dir failure must build the shared space diagnostic")
assert_contains('stage_mod.free_space and stage_mod.free_space()',
  "recovery-dir failure must query stage_mod's free-space helper")

-- serialize_config_backup() must run BEFORE fs.makeDir(RECOVERY_DIR), so a
-- makeDir failure can still report an accurate "needed" byte count instead
-- of a bare "out of space".
local serialize_pos = src:find("local serialized = serialize_config_backup(config_backup)", 1, true)
local makedir_pos = src:find("pcall(fs.makeDir, RECOVERY_DIR)", 1, true)
if not (serialize_pos and makedir_pos and serialize_pos < makedir_pos) then
  error("serialize_config_backup() must be computed before fs.makeDir(RECOVERY_DIR) is attempted")
end

-- installer/stage.lua must actually export what init.lua now calls.
local stage_src = read_file(repo_root .. "/xreactor/installer/stage.lua")
if not stage_src:find("function M.space_diagnostic(", 1, true) then
  error("installer/stage.lua must export M.space_diagnostic()")
end
if not stage_src:find("M.free_space = free_space", 1, true) then
  error("installer/stage.lua must export M.free_space()")
end

print("installer_init_recovery_dir_space_diagnostic_test.lua: ok")
