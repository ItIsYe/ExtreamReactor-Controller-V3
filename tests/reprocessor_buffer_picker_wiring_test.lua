-- tests/reprocessor_buffer_picker_wiring_test.lua
--
-- Structural check that nodes/reprocessor/main.lua actually wires the
-- PUFFER picker (buffer_candidate_names()/write_buffers()) into
-- color_router_ui_lib.new() -- main.lua has heavy boot-time side effects
-- and cannot be require()'d directly (matching this repo's existing
-- pattern for such checks, e.g. install_p0_2_quiesce_wiring_test.lua).
-- The actual UI behavior is driven directly in
-- tests/reprocessor_color_router_ui_buffers_test.lua.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read(repo_root .. "/xreactor/nodes/reprocessor/main.lua")

local function assert_contains(needle, label)
  if not src:find(needle, 1, true) then
    error("main.lua: expected marker not found (" .. label .. "): " .. needle)
  end
end

assert_contains("local function is_buffer_method_set(method_set)", "shared buffer-signature predicate")
assert_contains("local function buffer_candidate_names()", "live buffer candidate scanner")
assert_contains("local function write_buffers(list)", "buffer list persistence")
assert_contains("get_buffer_candidates = buffer_candidate_names", "wired into color_router_ui_lib.new()")
assert_contains("write_buffers = write_buffers", "wired into color_router_ui_lib.new()")

-- discover()'s real buffer match must use the SAME predicate the picker
-- uses, so a peripheral that shows up as pickable is also the one
-- discover() actually binds as a buffer.
assert_contains("match = is_buffer_method_set,", "discover() must reuse the shared predicate, not a separate copy")

print("reprocessor_buffer_picker_wiring_test.lua: ok")
