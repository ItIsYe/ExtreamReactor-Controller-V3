local M = {}

function M.is_xreactor_startup(content)
  if not content then
    return false
  end
  if content:find("/xreactor/start.lua", 1, true) then
    return true
  end
  if content:find("XReactor", 1, true) then
    return true
  end
  return false
end

function M.ensure_startup_script(ctx)
  local existing = nil
  if ctx.fs.exists(ctx.constants.STARTUP_PATH) then
    existing = ctx.read_file(ctx.constants.STARTUP_PATH)
  end

  if existing and not M.is_xreactor_startup(existing) then
    ctx.warn("Startup file exists and does not belong to XReactor; leaving unchanged")
    return
  end

  local ok, err = ctx.write_file(ctx.constants.STARTUP_PATH, ctx.constants.STARTUP_CONTENT)
  if not ok then
    ctx.warn("Failed to write startup file: " .. tostring(err))
    return
  end
  ctx.info("Startup file configured")
end

function M.ensure_auto_update_config(ctx)
  local CONFIG_PATH = "/xreactor/config/remote_update.lua"
  local CONFIG_DIR  = "/xreactor/config"
  if ctx.fs.exists(CONFIG_PATH) then
    ctx.info("Auto-update config already exists")
    return
  end
  if not ctx.fs.exists(CONFIG_DIR) then
    pcall(ctx.fs.makeDir, CONFIG_DIR)
  end
  local content = [[
return {
  enabled      = true,
  auto_update  = true,
  check_interval_s = 120,
}
]]
  local ok, err = ctx.write_file(CONFIG_PATH, content)
  if not ok then
    ctx.warn("Failed to write auto-update config: " .. tostring(err))
    return
  end
  ctx.info("Auto-update config created")
end

return M
