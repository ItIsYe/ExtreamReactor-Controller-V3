-- tests/auto_update_single_attempt_force_test.lua
--
-- Regression test (operator decision 2026-09-17, following up on the
-- FORCE_AFTER_FAILURES feature from earlier the same day): "die drei
-- Versuche sollen raus, es soll alles zwangsweise runtergefahren werden
-- und dann geupdated werden" -- remove the multi-attempt escalation
-- (3 consecutive 60s quiesce-wait cycles across separate scheduled update
-- checks before finally forcing) entirely. installer/auto_update.lua's
-- request_and_await_quiesce() must now wait exactly ONE QUIESCE_TIMEOUT_S
-- period and, on timeout, force the update through immediately -- no
-- failure counter, no safe-reboot-and-retry-later branch, no
-- reset-and-stay-pending branch.
--
-- request_and_await_quiesce() is local and not exported (same reasoning
-- as install_p0_2_quiesce_wiring_test.lua/auto_update_quiesce_timeout_
-- budget_test.lua), so this is a structural source check.

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

local function assert_not_contains(src, needle, label)
  if src:find(needle, 1, true) then
    error(label .. ": marker must NOT be present anymore: " .. needle)
  end
end

local repo_root = os.getenv("REPO_ROOT") or "."

local auto_update_src = read_file(repo_root .. "/xreactor/installer/auto_update.lua")
assert_not_contains(auto_update_src, "FORCE_AFTER_FAILURES", "installer/auto_update.lua")
assert_not_contains(auto_update_src, "record_quiesce_timeout", "installer/auto_update.lua")
assert_not_contains(auto_update_src, "reset_quiesce_failures", "installer/auto_update.lua")
assert_not_contains(auto_update_src, "quiesce_attempted == true", "installer/auto_update.lua")
assert_not_contains(auto_update_src, "update_handshake.reset(handshake) ~= true", "installer/auto_update.lua")

-- The single wait must be immediately followed by an unconditional force
-- (a plain "return true" right after the wait fails), not by any branch
-- that could return false / reboot / leave the request pending.
local wait_pos = auto_update_src:find("wait_for_runtime_stopped(handshake, QUIESCE_TIMEOUT_S)", 1, true)
if not wait_pos then
  error("installer/auto_update.lua: expected marker not found: wait_for_runtime_stopped(handshake, QUIESCE_TIMEOUT_S)")
end
local after_wait = auto_update_src:sub(wait_pos, wait_pos + 600)
assert_contains(after_wait, "Update wird ohne volle Sicherheits-Bestaetigung erzwungen", "installer/auto_update.lua (post-wait branch)")
assert_contains(after_wait, "return true", "installer/auto_update.lua (post-wait branch)")

local handshake_src = read_file(repo_root .. "/xreactor/core/update_handshake.lua")
assert_not_contains(handshake_src, "quiesce_failures", "core/update_handshake.lua")
assert_not_contains(handshake_src, "record_quiesce_timeout", "core/update_handshake.lua")
assert_not_contains(handshake_src, "reset_quiesce_failures", "core/update_handshake.lua")

print("auto_update_single_attempt_force_test.lua: ok")
