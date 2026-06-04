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
    return true
  end

  local ok, err = ctx.write_file(ctx.constants.STARTUP_PATH, ctx.constants.STARTUP_CONTENT)
  if not ok then
    ctx.warn("Failed to write startup file: " .. tostring(err))
    return false, err
  end
  ctx.info("Startup file configured")
  return true
end

function M.write_startup(ctx, role_label)
  return M.ensure_startup_script(ctx, role_label)
end

return M
