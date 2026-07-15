-- Funktionaler Verifikationstest fuer nodes/log_collector/default_ui.lua
-- (LOG-P2, siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md
-- Abschnitt 10). Laedt das echte Modul und prueft, dass M.render(ctx) mit
-- einem realistischen ctx durchlaeuft (kein Fehler), die Basis-UI-Aufrufe
-- (flush_ui, line_ui, badge_ui) tatsaechlich benutzt und stats.last_draw_s
-- aktualisiert -- exakt dieselbe Erwartung wie an mockup_ui.lua (M.render(ctx)).

local REPO = os.getenv("REPO_ROOT") or "."
if type(package) == "table" and type(package.path) == "string" then
  package.path = REPO .. "/xreactor/?.lua;" .. REPO .. "/xreactor/?/init.lua;" .. package.path
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local ok_mod, default_ui = pcall(require, "nodes.log_collector.default_ui")
check(ok_mod, "default_ui.lua must load without error (got " .. tostring(default_ui) .. ")")
check(type(default_ui) == "table" and type(default_ui.render) == "function",
  "default_ui.render must be a function")

if ok_mod and type(default_ui) == "table" and type(default_ui.render) == "function" then
  local line_calls, badge_calls, flush_calls = 0, 0, 0

  local ctx = {
    stats = {
      last_error = nil, paused = false, modems = { "back" }, modem = "back",
      disks = { { id = 1, mount = "/disk1", role = "LOG" } },
      last_write_index = 1, last_write_path = "/disk1/log.txt",
      received = 10, written = 9, dropped = 1, duplicates = 0,
      ack_sent = 9, wiped = 0, paused_dropped = 0,
      modem_refreshes = 2, disk_refreshes = 1,
      last_role = "RT", last_node = "rt-1", last_level = "INFO",
      display_name = "term",
    },
    live_diag = { "boot ok" },
    channel = 6503,
    min_free_bytes = 8192,
    disks_per_role = 4,
    color = function(name, fallback) return fallback end,
    now_s = function() return 42 end,
    free_space = function(mount) return 100000 end,
    begin_frame = function() return 40, 24 end,
    queue_segment = function() end,
    line_ui = function() line_calls = line_calls + 1 end,
    badge_ui = function() badge_calls = badge_calls + 1; return 6 end,
    progress_ui = function() end,
    draw_pause_button = function() end,
    draw_log_mode_buttons = function() end,
    flush_ui = function() flush_calls = flush_calls + 1 end,
    log_mode = function() return "all" end,
  }

  local ok_render, render_err = pcall(default_ui.render, ctx)
  check(ok_render, "render(ctx) must not raise on a realistic ctx (got " .. tostring(render_err) .. ")")
  check(line_calls > 0, "render must draw at least one line via ctx.line_ui")
  check(badge_calls > 0, "render must draw at least one badge via ctx.badge_ui")
  check(flush_calls == 1, "render must call ctx.flush_ui exactly once")
  check(ctx.stats.last_draw_s == 42, "render must set stats.last_draw_s from ctx.now_s()")

  -- No writable disk: must not error, must show the "no disk" line instead.
  line_calls, flush_calls = 0, 0
  ctx.stats.disks = {}
  ctx.stats.last_write_index = nil
  local ok_render2, render_err2 = pcall(default_ui.render, ctx)
  check(ok_render2, "render(ctx) must not raise with zero disks (got " .. tostring(render_err2) .. ")")
  check(flush_calls == 1, "render must still flush once with zero disks")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
