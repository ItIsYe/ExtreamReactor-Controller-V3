local M = {}

function M.ensure_role_config(ctx, root_path, role_label)
  local role_path = root_path .. "/config/role.lua"
  local content = string.format("return { role = %q }\n", role_label)
  local ok, err = ctx.write_file(role_path, content)
  if not ok then
    ctx.warn("Failed to write role config: " .. tostring(err))
  end
end

function M.read_role_config(ctx)
  local role_path = ctx.constants.INSTALL_ROOT .. "/config/role.lua"
  if not ctx.fs.exists(role_path) then
    return nil
  end
  local content = ctx.read_file(role_path)
  if not content then
    return nil
  end
  local loader = load(content, "=role", "t", {})
  if not loader then
    return nil
  end
  local ok, result = pcall(loader)
  if not ok then
    return nil
  end
  if type(result) == "table" and type(result.role) == "string" then
    return result.role
  end
  return nil
end

function M.stage_expected_files(ctx, expected)
  if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
    ctx.info("Removing stale stage root")
    ctx.fs.delete(ctx.constants.STAGE_ROOT)
  end
  if not ctx.safe_mkdir(ctx.constants.STAGE_ROOT) then
    ctx.fatal("Unable to create stage root: " .. ctx.constants.STAGE_ROOT)
  end
  ctx.info("Installing files into stage root: " .. ctx.constants.STAGE_ROOT)

  for _, entry in pairs(expected) do
    local target_path = ctx.constants.STAGE_ROOT .. "/" .. entry.path
    local ok, err = ctx.download_file(entry.path, target_path, entry)
    if not ok then
      if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
        ctx.fs.delete(ctx.constants.STAGE_ROOT)
      end
      return false, "Download failed: " .. tostring(err)
    end
  end
  return true
end

function M.copy_config_to_stage(ctx)
  local src = ctx.constants.INSTALL_ROOT .. "/config"
  local dst = ctx.constants.STAGE_ROOT .. "/config"
  if ctx.fs.exists(src) and ctx.fs.isDir(src) then
    if ctx.fs.exists(dst) then
      ctx.fs.delete(dst)
    end
    ctx.fs.copy(src, dst)
  end
end

function M.verify_stage(ctx, expected)
  for rel, entry in pairs(expected) do
    local path = ctx.constants.STAGE_ROOT .. "/" .. rel
    if not ctx.fs.exists(path) then
      return false, "staged file missing: " .. rel
    end
    local content = ctx.read_file(path)
    if not content then
      return false, "staged file unreadable: " .. rel
    end
    if entry.hash and not ctx.hash_matches(entry, content) then
      return false, "staged hash mismatch: " .. rel
    end
  end
  return true
end

function M.activate_stage(ctx)
  ctx.info("Committing staged install")
  if ctx.fs.exists(ctx.constants.BACKUP_ROOT) then
    ctx.fs.delete(ctx.constants.BACKUP_ROOT)
  end

  if ctx.fs.exists(ctx.constants.INSTALL_ROOT) then
    ctx.info("Moving active install to backup")
    ctx.fs.move(ctx.constants.INSTALL_ROOT, ctx.constants.BACKUP_ROOT)
  end

  ctx.info("Activating stage as live install")
  local moved = pcall(ctx.fs.move, ctx.constants.STAGE_ROOT, ctx.constants.INSTALL_ROOT)
  if not moved then
    ctx.warn("Stage activation failed; attempting rollback")
    if ctx.fs.exists(ctx.constants.INSTALL_ROOT) then
      ctx.fs.delete(ctx.constants.INSTALL_ROOT)
    end
    if ctx.fs.exists(ctx.constants.BACKUP_ROOT) then
      ctx.fs.move(ctx.constants.BACKUP_ROOT, ctx.constants.INSTALL_ROOT)
    end
    if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
      ctx.fs.delete(ctx.constants.STAGE_ROOT)
    end
    ctx.fatal("Failed to activate staged install")
  end

  if ctx.fs.exists(ctx.constants.BACKUP_ROOT) then
    ctx.info("Removing backup after successful commit")
    ctx.fs.delete(ctx.constants.BACKUP_ROOT)
  end
  if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
    ctx.fs.delete(ctx.constants.STAGE_ROOT)
  end
end

return M
