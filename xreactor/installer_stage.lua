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

local function metadata_body_for(ctx, rel_path)
  if rel_path == "release.lua" then
    return ctx.remote_release_body or ctx.release_metadata_body
  end
  if rel_path == "manifest.lua" then
    return ctx.remote_manifest_body or ctx.manifest_metadata_body
  end
  return nil
end

local function warn_or_fail_metadata(ctx, message)
  if ctx and ctx.source_ref == "beta" then
    if ctx.warn then ctx.warn(message) end
    return true
  end
  return false, message
end

local function write_cached_metadata(ctx, entry, target_path, body)
  if type(body) ~= "string" or body == "" then
    return false, "remote metadata cache missing for " .. tostring(entry.path)
  end
  local size_ok, actual_size = ctx.size_matches(entry, body)
  if not size_ok then
    local ok, err = warn_or_fail_metadata(ctx, string.format(
      "Ignoring stale remote metadata size for %s expected=%s actual=%s",
      tostring(entry.path),
      tostring(entry.size_bytes),
      tostring(actual_size)
    ))
    if not ok then return false, err end
  end
  local hash_ok, actual_hash = ctx.hash_matches(entry, body)
  if not hash_ok then
    local ok, err = warn_or_fail_metadata(ctx, string.format(
      "Ignoring stale remote metadata hash for %s expected=%s actual=%s",
      tostring(entry.path),
      tostring(entry.hash),
      tostring(actual_hash)
    ))
    if not ok then return false, err end
  end
  local ok, err = ctx.write_file(target_path, body)
  if ok then
    ok, err = ctx.validate_download(target_path)
  end
  return ok, err
end

local function ordered_entries(expected)
  local list = {}
  for rel, entry in pairs(expected or {}) do
    local e = entry or { path = rel }
    e.path = e.path or rel
    table.insert(list, e)
  end
  table.sort(list, function(a, b)
    local sa = tonumber(a.size_bytes) or 0
    local sb = tonumber(b.size_bytes) or 0
    if sa ~= sb then return sa > sb end
    return tostring(a.path or "") < tostring(b.path or "")
  end)
  return list
end

function M.stage_expected_files(ctx, expected)
  if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
    ctx.info("Removing stale stage root")
    ctx.fs.delete(ctx.constants.STAGE_ROOT)
  end
  if ctx.fs.exists(ctx.constants.BACKUP_ROOT) then
    ctx.info("Removing stale backup root before staging")
    ctx.fs.delete(ctx.constants.BACKUP_ROOT)
  end
  if not ctx.safe_mkdir(ctx.constants.STAGE_ROOT) then
    ctx.fatal("Unable to create stage root: " .. ctx.constants.STAGE_ROOT)
  end
  ctx.info("Installing files into stage root: " .. ctx.constants.STAGE_ROOT)

  for _, entry in ipairs(ordered_entries(expected)) do
    local target_path = ctx.constants.STAGE_ROOT .. "/" .. entry.path
    local ok, err
    local metadata_body = metadata_body_for(ctx, entry.path)
    if metadata_body then
      ctx.info("Writing verified remote metadata body for " .. tostring(entry.path))
      ok, err = write_cached_metadata(ctx, entry, target_path, metadata_body)
    else
      ok, err = ctx.download_file(entry.path, target_path, entry)
    end
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
    local size_ok, actual_size = ctx.size_matches(entry, content)
    if not size_ok then
      local ok, err = warn_or_fail_metadata(ctx, string.format(
        "Ignoring stale staged size for %s expected=%s actual=%s",
        tostring(rel),
        tostring(entry.size_bytes),
        tostring(actual_size)
      ))
      if not ok then return false, err end
    end
    if entry.hash then
      local hash_ok, actual_hash = ctx.hash_matches(entry, content)
      if not hash_ok then
        local ok, err = warn_or_fail_metadata(ctx, string.format(
          "Ignoring stale staged hash for %s expected=%s actual=%s",
          tostring(rel),
          tostring(entry.hash),
          tostring(actual_hash)
        ))
        if not ok then return false, err end
      end
    end
    if rel:sub(-4) == ".lua" then
      local loader, parse_err = ctx.compile_lua(path, content)
      if not loader then
        return false, string.format(
          "staged lua parse error: %s (%s)",
          tostring(rel),
          tostring(parse_err)
        )
      end
    end
  end
  return true
end

function M.validate_stage(ctx, expected)
  return M.verify_stage(ctx, expected)
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
  return true
end

function M.commit_stage(ctx)
  M.copy_config_to_stage(ctx)
  return M.activate_stage(ctx)
end

return M
