local M = {}

local function normalize_free_space(value)
  if type(value) == "number" then
    if value < 0 then
      return math.huge
    end
    return value
  end
  if type(value) == "string" then
    local trimmed = tostring(value):match("^%s*(.-)%s*$")
    if trimmed == "unlimited" then
      return math.huge
    end
    local parsed = tonumber(trimmed)
    if parsed then
      if parsed < 0 then
        return math.huge
      end
      return parsed
    end
  end
  return nil
end

function M.measure_tree_size(fs_api, path)
  if not fs_api.exists(path) then
    return 0
  end
  if not fs_api.isDir(path) then
    return math.max(0, tonumber(fs_api.getSize(path)) or 0)
  end
  local total = 0
  for _, name in ipairs(fs_api.list(path)) do
    total = total + M.measure_tree_size(fs_api, fs_api.combine(path, name))
  end
  return total
end

function M.estimate_required_storage(fs_api, install_root, expected, mode, constants)
  local total = 0
  local growth_bytes = 0
  local existing_bytes = 0
  for rel, entry in pairs(expected) do
    local expected_size = math.max(0, tonumber(entry.size_bytes) or 0)
    total = total + expected_size
    local live_path = fs_api.combine(install_root, rel)
    if fs_api.exists(live_path) and not fs_api.isDir(live_path) then
      local current_size = math.max(0, tonumber(fs_api.getSize(live_path)) or 0)
      existing_bytes = existing_bytes + current_size
      if expected_size > current_size then
        growth_bytes = growth_bytes + (expected_size - current_size)
      end
    else
      growth_bytes = growth_bytes + expected_size
    end
  end
  local buffer_base = mode == "update" and constants.STORAGE_UPDATE_BUFFER_BYTES or constants.STORAGE_BUFFER_BYTES
  local stage_peak_bytes = total
  local estimate_base = stage_peak_bytes
  local percent_buffer = math.floor(estimate_base * constants.STORAGE_PERCENT_BUFFER)
  local update_growth_buffer = mode == "update" and math.floor(growth_bytes * 0.03) or 0
  local required = math.max(constants.STORAGE_MIN_REQUIRED_BYTES, stage_peak_bytes + buffer_base + percent_buffer + update_growth_buffer)
  return {
    mode = mode or "install",
    payload_bytes = total,
    growth_bytes = growth_bytes,
    existing_bytes = existing_bytes,
    stage_peak_bytes = stage_peak_bytes,
    estimate_base_bytes = estimate_base,
    fixed_buffer_bytes = buffer_base,
    percent_buffer_bytes = percent_buffer,
    growth_buffer_bytes = update_growth_buffer,
    required_bytes = required
  }
end

function M.cleanup_stage_and_logs(ctx, opts)
  opts = opts or {}
  local reclaimed = { stage = 0, backup = 0, logs = 0, rotated = 0, temp = 0 }
  if ctx.fs.exists(ctx.constants.STAGE_ROOT) then
    reclaimed.stage = M.measure_tree_size(ctx.fs, ctx.constants.STAGE_ROOT)
    ctx.info("Cleaning stale stage directory")
    ctx.fs.delete(ctx.constants.STAGE_ROOT)
  end
  if opts.cleanup_backup and ctx.fs.exists(ctx.constants.BACKUP_ROOT) then
    reclaimed.backup = M.measure_tree_size(ctx.fs, ctx.constants.BACKUP_ROOT)
    ctx.info("Cleaning stale backup directory")
    ctx.fs.delete(ctx.constants.BACKUP_ROOT)
  end
  if opts.cleanup_logs and ctx.fs.exists(ctx.constants.LOG_DIR) then
    reclaimed.logs = M.measure_tree_size(ctx.fs, ctx.constants.LOG_DIR)
    ctx.info("Cleaning log directory to recover storage")
    ctx.fs.delete(ctx.constants.LOG_DIR)
  end
  if ctx.fs.exists(ctx.constants.LOG_DIR) and ctx.fs.isDir(ctx.constants.LOG_DIR) then
    for _, name in ipairs(ctx.fs.list(ctx.constants.LOG_DIR)) do
      if name:match("^installer_[a-z0-9_%-]+%.log%.%d+$") then
        local rotated = ctx.fs.combine(ctx.constants.LOG_DIR, name)
        if ctx.fs.exists(rotated) then
          reclaimed.rotated = reclaimed.rotated + math.max(0, tonumber(ctx.fs.getSize(rotated)) or 0)
          ctx.fs.delete(rotated)
        end
      end
    end
  end
  local temp_paths = {
    "/xreactor_stage.tmp",
    "/xreactor_backup_prev.tmp",
    "/xreactor_update.tmp",
    "/xreactor_update.rollback",
    "/xreactor_update.manifest.tmp"
  }
  for _, path in ipairs(temp_paths) do
    if ctx.fs.exists(path) then
      reclaimed.temp = reclaimed.temp + M.measure_tree_size(ctx.fs, path)
      ctx.fs.delete(path)
    end
  end
  return reclaimed
end

function M.preflight_storage(ctx, storage_plan, opts)
  opts = opts or {}
  if not ctx.fs.getFreeSpace then
    ctx.warn("Free space check unavailable; continuing without preflight")
    return true
  end

  local required_bytes = storage_plan.required_bytes
  local free_raw = ctx.fs.getFreeSpace("/")
  local free_bytes = normalize_free_space(free_raw)
  if free_bytes == nil then
    ctx.warn("Storage preflight: fs.getFreeSpace returned unsupported value; skipping strict check (" .. tostring(free_raw) .. ")")
    return true
  end
  ctx.info(string.format("Storage preflight free bytes: %s", tostring(free_bytes)))
  ctx.info(string.format("Storage preflight payload estimate: %d", storage_plan.payload_bytes))
  ctx.info(string.format("Storage preflight growth estimate: %d (existing=%d)", storage_plan.growth_bytes or 0, storage_plan.existing_bytes or 0))
  ctx.info(string.format("Storage preflight stage peak estimate: %d (estimate_base=%d)", storage_plan.stage_peak_bytes or 0, storage_plan.estimate_base_bytes or 0))
  ctx.info(string.format(
    "Storage preflight safety buffer: %d fixed + %d dynamic + %d growth",
    storage_plan.fixed_buffer_bytes,
    storage_plan.percent_buffer_bytes,
    storage_plan.growth_buffer_bytes or 0
  ))

  if free_bytes >= required_bytes then
    ctx.info(string.format(
      "Storage preflight OK (mode=%s free=%s payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
      tostring(storage_plan.mode or "install"),
      tostring(free_bytes),
      storage_plan.payload_bytes,
      storage_plan.growth_bytes or 0,
      storage_plan.stage_peak_bytes or 0,
      storage_plan.fixed_buffer_bytes,
      storage_plan.percent_buffer_bytes,
      storage_plan.growth_buffer_bytes or 0,
      required_bytes
    ))
    ctx.info("Storage preflight result: ok")
    return true
  end

  ctx.warn(string.format(
    "Storage low before install/update (mode=%s free=%s payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
    tostring(storage_plan.mode or "install"),
    tostring(free_bytes),
    storage_plan.payload_bytes,
    storage_plan.growth_bytes or 0,
    storage_plan.stage_peak_bytes or 0,
    storage_plan.fixed_buffer_bytes,
    storage_plan.percent_buffer_bytes,
    storage_plan.growth_buffer_bytes or 0,
    required_bytes
  ))
  ctx.warn("Storage preflight result: not ok")

  if opts.allow_cleanup then
    local reclaimed = M.cleanup_stage_and_logs(ctx, opts)
    free_raw = ctx.fs.getFreeSpace("/")
    free_bytes = normalize_free_space(free_raw)
    if free_bytes == nil then
      ctx.warn("Storage preflight: fs.getFreeSpace returned unsupported value after cleanup; skipping strict check (" .. tostring(free_raw) .. ")")
      return true
    end
    ctx.info(string.format("Storage cleanup reclaimed bytes: stage=%d backup=%d logs=%d rotated=%d temp=%d", reclaimed.stage or 0, reclaimed.backup or 0, reclaimed.logs or 0, reclaimed.rotated or 0, reclaimed.temp or 0))
    if free_bytes >= required_bytes then
      ctx.info(string.format(
        "Storage preflight OK after cleanup (mode=%s free=%s payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
        tostring(storage_plan.mode or "install"),
        tostring(free_bytes),
        storage_plan.payload_bytes,
        storage_plan.growth_bytes or 0,
        storage_plan.stage_peak_bytes or 0,
        storage_plan.fixed_buffer_bytes,
        storage_plan.percent_buffer_bytes,
        storage_plan.growth_buffer_bytes or 0,
        required_bytes
      ))
      ctx.info("Storage preflight result after cleanup: ok")
      return true
    end
    ctx.warn("Storage preflight result after cleanup: not ok")
  end

  if storage_plan.mode == "update" and opts.allow_low_space_update_attempt then
    ctx.warn(string.format(
      "Storage preflight continuing in low-space update mode (free=%s required=%d payload=%d); staging will fail safely if space is still insufficient",
      tostring(free_bytes),
      required_bytes,
      storage_plan.payload_bytes or 0
    ))
    return true
  end

  return false, string.format(
    "Not enough free space (mode=%s free=%s payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
    tostring(storage_plan.mode or "install"),
    tostring(free_bytes),
    storage_plan.payload_bytes,
    storage_plan.growth_bytes or 0,
    storage_plan.stage_peak_bytes or 0,
    storage_plan.fixed_buffer_bytes,
    storage_plan.percent_buffer_bytes,
    storage_plan.growth_buffer_bytes or 0,
    required_bytes
  )
end

return M