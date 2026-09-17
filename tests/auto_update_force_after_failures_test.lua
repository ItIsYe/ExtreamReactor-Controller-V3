-- tests/auto_update_force_after_failures_test.lua
--
-- Regression test (user report 2026-09-17: "das update klappt nicht immer
-- weil das update immer wieder ein timeout bekommt weil irgendwas noch
-- laeuft. Ich moechte, dass das update fest eingequeut wird und dann auch
-- gemacht wird"). Before this fix, EVERY quiesce timeout for a pending
-- update either safely rebooted without installing (quiesce_attempted ==
-- true / SAFE_OUTPUTS_APPLIED / RUNTIME_STOPPED branch) or reset the
-- handshake back to IDLE and left the update "vorgemerkt" (pending) for
-- the next periodic cycle -- neither branch ever actually ran run_update().
-- A role that never reached a confirmed safe state (a permanently
-- offline/unresponsive valve, or the whole event loop wedged behind a slow
-- synchronous peripheral call -- see nodes/support/runtime.lua) meant the
-- exact same timeout repeated forever, on every single check, and the
-- update never installed.
--
-- request_and_await_quiesce() is local to installer/auto_update.lua and
-- not exported, so (matching this repo's existing install_p0_2_quiesce_
-- wiring_test.lua/auto_update_quiesce_timeout_budget_test.lua pattern) this
-- is a structural source check: after FORCE_AFTER_FAILURES consecutive
-- timeouts for the SAME pending update, the safety wait must be skipped
-- and the update must proceed anyway -- checked BEFORE the safe-reboot/
-- safe-reset branches so it actually takes effect instead of being
-- unreachable dead code. core_update_handshake_test.lua drives the actual
-- counter semantics (record_quiesce_timeout/reset_quiesce_failures)
-- directly against the real module.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function assert_contains(src, needle, label)
  if not src:find(needle, 1, true) then
    error(label .. ": expected marker not found: " .. needle)
  end
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read_file(repo_root .. "/xreactor/installer/auto_update.lua")

local force_const_pos = src:find("FORCE_AFTER_FAILURES%s*=%s*%d+")
if not force_const_pos then
  error("installer/auto_update.lua: expected a FORCE_AFTER_FAILURES threshold constant")
end

assert_contains(src, "update_handshake.record_quiesce_timeout(handshake)", "installer/auto_update.lua")
assert_contains(src, "update_handshake.reset_quiesce_failures(handshake)", "installer/auto_update.lua")

-- The force-escalation check must come BEFORE both existing safety
-- branches (quiesce_attempted-reboot and reset-and-retry) -- otherwise it
-- is unreachable and the exact bug this fix addresses would still occur.
local wait_pos = src:find("wait_for_runtime_stopped(handshake, QUIESCE_TIMEOUT_S)", 1, true)
local force_check_pos = src:find("failures >= FORCE_AFTER_FAILURES", 1, true)
local reboot_branch_pos = src:find("handshake.quiesce_attempted == true", 1, true)
local reset_branch_pos = src:find("update_handshake.reset(handshake) ~= true", 1, true)

if not (wait_pos and force_check_pos and reboot_branch_pos and reset_branch_pos) then
  error("installer/auto_update.lua: could not locate all expected quiesce-timeout branches")
end
if not (wait_pos < force_check_pos and force_check_pos < reboot_branch_pos
    and force_check_pos < reset_branch_pos) then
  error("installer/auto_update.lua: FORCE_AFTER_FAILURES check must run BEFORE the safe "
    .. "reboot/reset branches, otherwise repeated timeouts can never actually force the update through")
end

print("auto_update_force_after_failures_test.lua: ok")
