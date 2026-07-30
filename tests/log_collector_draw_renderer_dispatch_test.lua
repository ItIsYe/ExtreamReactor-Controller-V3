-- Funktionaler Verifikationstest fuer die LOG-P2-Renderer-Schnittstelle in
-- nodes/log_collector/main.lua (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 10). Extrahiert die exakten
-- RENDERER_MODULE/draw_fallback/draw()-Funktionen aus der echten Datei und
-- prueft: Happy Path ruft renderer.render(ctx) mit den erwarteten Feldern
-- auf; fehlendes Renderer-Modul und ein Laufzeitfehler im Renderer loesen
-- beide den sichtbaren Fallback aus statt abzustuerzen; der globale
-- Renderer-Selektor XR_LOG_RENDERER_MODULE wird respektiert (kein
-- Quelltext-Patching mehr noetig, um z.B. mockup_ui.lua zu waehlen).

local REPO = os.getenv("REPO_ROOT") or "."

local function read_file(p)
  local f = assert(io.open(p, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

local function extract(s, start_marker, end_marker)
  local a = s:find(start_marker, 1, true)
  assert(a, "start marker not found: " .. start_marker)
  local b = s:find(end_marker, a, true)
  assert(b, "end marker not found: " .. end_marker)
  return s:sub(a, b + #end_marker - 1)
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local src = read_file(REPO .. "/xreactor/nodes/log_collector/main.lua")
local block_src = extract(src,
  "local RENDERER_MODULE = (type(_G) == \"table\"",
  "\nend\n\n-- ── Display selection")
-- drop the trailing marker comment we matched past "end" of draw()
block_src = block_src:gsub("\n%-%- ── Display selection.*$", "")
block_src = block_src .. "\nreturn draw"

local function fit(text, width)
  local s = tostring(text or "")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  return s:sub(1, w - 1) .. "~"
end

local function make_env(require_impl)
  local self_log_calls = {}
  local flush_calls = 0
  local ui_lines = {}

  local env = {
    _G = _G,
    tostring = tostring, tonumber = tonumber, string = string, math = math, type = type, pcall = pcall,
    require = require_impl,
    begin_frame = function() return 40, 20 end,
    line_ui = function(x, y, text, fg, bg) table.insert(ui_lines, { x = x, y = y, text = text }) end,
    color = function(name, fallback) return fallback end,
    fit = fit,
    stats = { received = 3, written = 2, dropped = 0, disks = {}, modem = "" },
    flush_ui = function() flush_calls = flush_calls + 1 end,
    now_s = function() return 111 end,
    self_log = function(msg, level) table.insert(self_log_calls, { msg = msg, level = level }) end,
    refresh_disks = function() end,
    refresh_modems = function() end,
    live_diag = {},
    CHANNEL = 6503,
    MIN_FREE_BYTES = 8192,
    DISKS_PER_ROLE = 4,
    queue_segment = function() end,
    badge_ui = function() return 4 end,
    progress_ui = function() end,
    draw_pause_button = function() end,
    draw_log_mode_buttons = function() end,
    utils = nil,
  }
  env._ENV = env
  return env, self_log_calls, function() return flush_calls end, ui_lines
end

------------------------------------------------------------------------------
-- Happy Path: Standard-Renderer wird gefunden und aufgerufen.
------------------------------------------------------------------------------

do
  local render_calls = {}
  local require_impl = function(name)
    check(name == "nodes.log_collector.default_ui", "default RENDERER_MODULE should be default_ui (got " .. tostring(name) .. ")")
    return {
      render = function(ctx) table.insert(render_calls, ctx) end,
    }
  end
  local env, self_log_calls, get_flush_calls = make_env(require_impl)
  local chunk = assert(load(block_src, "=draw_happy_path", "t", env))
  local draw = chunk()
  draw()

  check(#render_calls == 1, "renderer.render should be called exactly once (got " .. #render_calls .. ")")
  check(#self_log_calls == 0, "no self_log call expected on happy path")
  check(get_flush_calls() == 0, "draw_fallback's flush_ui must NOT run on happy path (renderer owns flush)")
  local ctx = render_calls[1]
  check(ctx.stats == env.stats, "ctx.stats must be the real stats table")
  check(ctx.channel == 6503, "ctx.channel must be forwarded")
  check(ctx.disks_per_role == 4, "ctx.disks_per_role must be forwarded")
  check(type(ctx.log_mode) == "function" and ctx.log_mode() == "all", "ctx.log_mode() should default to 'all' without utils")
end

------------------------------------------------------------------------------
-- Renderer-Modul fehlt (require schlaegt fehl): sichtbarer Fallback statt Crash.
------------------------------------------------------------------------------

do
  local require_impl = function(name) error("module '" .. name .. "' not found") end
  local env, self_log_calls, get_flush_calls = make_env(require_impl)
  local chunk = assert(load(block_src, "=draw_missing_renderer", "t", env))
  local draw = chunk()

  local ok = pcall(draw)
  check(ok, "draw() must not raise even if the renderer module is missing")
  check(#self_log_calls == 1, "missing renderer should be logged via self_log")
  check(get_flush_calls() == 1, "draw_fallback must run flush_ui exactly once")
end

------------------------------------------------------------------------------
-- Renderer wirft einen Laufzeitfehler: sichtbarer Fallback statt Crash.
------------------------------------------------------------------------------

do
  local require_impl = function(name)
    return { render = function(ctx) error("boom") end }
  end
  local env, self_log_calls, get_flush_calls = make_env(require_impl)
  local chunk = assert(load(block_src, "=draw_renderer_error", "t", env))
  local draw = chunk()

  local ok = pcall(draw)
  check(ok, "draw() must not raise even if the renderer's render() throws")
  check(#self_log_calls == 1, "renderer runtime error should be logged via self_log")
  check(get_flush_calls() == 1, "draw_fallback must run flush_ui exactly once")
end

------------------------------------------------------------------------------
-- Renderer-Auswahl per globalem Selektor (kein Quelltext-Patching mehr noetig).
------------------------------------------------------------------------------

do
  _G.XR_LOG_RENDERER_MODULE = "nodes.log_collector.mockup_ui"
  local seen_name
  local require_impl = function(name)
    seen_name = name
    return { render = function(ctx) end }
  end
  local env, self_log_calls = make_env(require_impl)
  local chunk = assert(load(block_src, "=draw_selector_override", "t", env))
  local draw = chunk()
  draw()
  _G.XR_LOG_RENDERER_MODULE = nil

  check(seen_name == "nodes.log_collector.mockup_ui", "RENDERER_MODULE must respect _G.XR_LOG_RENDERER_MODULE override (got " .. tostring(seen_name) .. ")")
  check(#self_log_calls == 0, "no self_log call expected when the selected renderer works")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
