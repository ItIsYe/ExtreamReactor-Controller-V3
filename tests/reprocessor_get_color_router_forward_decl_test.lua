-- tests/reprocessor_get_color_router_forward_decl_test.lua
--
-- Regression test confirmed by a real log export (2026-09-17,
-- xreactor_logs/reproc/pc-100.log): "Service tick failed (UI); retry in
-- ...s: ...s/reprocessor/main.lua:299: attempt to call global
-- 'get_color_router' (a nil value)" -- repeated on every single UI tick,
-- surfaced in-game as the REPROC UI ERROR / RENDER_FAILED screen on the
-- "Router" page (core/ui_router.lua's page.render pcall wrapper).
--
-- Root cause: render_monitor() (defined earlier in the file) builds a
-- pages table whose "Router" entry calls get_color_router() inside a
-- closure. get_color_router() itself was declared further down as
-- "local function get_color_router() ... end" -- Lua resolves free
-- variables inside a function literal against the lexical scope visible
-- AT COMPILE TIME, not when it later runs. Since no local named
-- get_color_router existed yet when render_monitor()'s closure was
-- compiled, the reference fell through to a global of that name, which is
-- never set -- deterministic nil-call on every render. Identical failure
-- class/fix as tests/log_collector_flush_bucket_send_ack_forward_decl_
-- test.lua's send_ack bug.
--
-- Fix: forward-declare "local get_color_router" BEFORE render_monitor(),
-- and assign to it later via "get_color_router = function() ... end"
-- (no "local") so the later definition binds to the SAME upvalue
-- render_monitor()'s closure already captured.
--
-- nodes/reprocessor/main.lua has heavy boot-time side effects and cannot
-- be require()'d directly, so (matching the log_collector precedent) this
-- is a structural source check: the forward declaration must exist before
-- render_monitor's definition, the later assignment must NOT re-declare a
-- shadowing local, and the ordering must be correct.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read(repo_root .. "/xreactor/nodes/reprocessor/main.lua")

local forward_decl_pos = src:find("\nlocal get_color_router\n", 1, true)
assert(forward_decl_pos, "expected 'local get_color_router' forward declaration")

local render_monitor_pos = src:find("\nlocal function render_monitor%(%)")
assert(render_monitor_pos, "expected render_monitor() definition")

local call_site_pos = src:find("get_color_router():render(", render_monitor_pos, true)
assert(call_site_pos, "expected a get_color_router():render(...) call site (inside render_monitor's pages table)")

local assignment_pos = src:find("\nget_color_router = function%(%)")
assert(assignment_pos, "expected 'get_color_router = function()' assignment (no 'local')")

assert(not src:find("local function get_color_router", 1, true),
  "get_color_router must NOT be declared as 'local function' -- that creates a new local " ..
  "invisible to render_monitor()'s already-compiled closure, reproducing the original bug")

assert(forward_decl_pos < render_monitor_pos,
  "the forward declaration must come BEFORE render_monitor(), otherwise render_monitor()'s " ..
  "closure still cannot see it as an upvalue")
assert(render_monitor_pos < call_site_pos,
  "sanity check: the call site should be inside/after render_monitor()")
assert(call_site_pos < assignment_pos,
  "sanity check: the real assignment should come after the call site, matching the original file layout")

print("reprocessor_get_color_router_forward_decl_test.lua: ok")
