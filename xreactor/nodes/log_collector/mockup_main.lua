-- LOG Collector mockup entrypoint.
-- Loads the proven collector runtime unchanged except for replacing its local draw()
-- function inside the same Lua chunk. This preserves access to all existing local
-- stats, incremental-buffer helpers, touch buttons, disk logic and modem logic.

local MAIN_PATH = "/xreactor/nodes/log_collector/main.lua"

local function read_all(path)
  if not fs or not fs.exists or not fs.exists(path) then return nil, "missing " .. tostring(path) end
  local f = fs.open(path, "r")
  if not f then return nil, "cannot open " .. tostring(path) end
  local src = f.readAll()
  f.close()
  return src
end

local source, read_err = read_all(MAIN_PATH)
if not source then error("LOG mockup loader: " .. tostring(read_err), 0) end

local draw_start = source:find("local function draw()", 1, true)
local display_marker = source:find("-- ── Display selection", 1, true)
if not draw_start or not display_marker or display_marker <= draw_start then
  error("LOG mockup loader: draw markers not found", 0)
end

local replacement = [=[local function draw()
  refresh_disks(false)
  refresh_modems(false)

  local ok_renderer, renderer = pcall(require, "nodes.log_collector.mockup_ui")
  if not ok_renderer or type(renderer) ~= "table" or type(renderer.render) ~= "function" then
    error("LOG mockup renderer unavailable: " .. tostring(renderer))
  end

  renderer.render({
    stats = stats,
    live_diag = live_diag,
    channel = CHANNEL,
    min_free_bytes = MIN_FREE_BYTES,
    color = color,
    now_s = now_s,
    free_space = free_space,
    begin_frame = begin_frame,
    queue_segment = queue_segment,
    line_ui = line_ui,
    badge_ui = badge_ui,
    progress_ui = progress_ui,
    draw_pause_button = draw_pause_button,
    draw_log_mode_buttons = draw_log_mode_buttons,
    flush_ui = flush_ui,
    log_mode = function()
      return utils and utils.get_log_mode and utils.get_log_mode() or "all"
    end,
  })
end

]=]

local patched = source:sub(1, draw_start - 1) .. replacement .. source:sub(display_marker)
local chunk, load_err = load(patched, "@" .. MAIN_PATH .. "#mockup", "t", _ENV)
if not chunk then error("LOG mockup loader syntax: " .. tostring(load_err), 0) end

return chunk()
