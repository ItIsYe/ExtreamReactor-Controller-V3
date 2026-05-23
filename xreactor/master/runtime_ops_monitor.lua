local M = {}

local function monitor_signature(monitors)
  local parts = {}
  for _, entry in ipairs(monitors or {}) do
    parts[#parts + 1] = table.concat({
      tostring(entry.id or entry.name),
      tostring(entry.width or "?"),
      tostring(entry.height or "?"),
      tostring(entry.layout_class or "?"),
      tostring(entry.text_scale or "?")
    }, ":")
  end
  return table.concat(parts, "|")
end

function M.refresh_monitors(runtime, force)
  local now = os.epoch("utc")
  if not runtime.refs.monitor_mgr then return end
  if not force and now - runtime.state.monitor_scan_last < 5000 then return end
  runtime.state.monitor_scan_last = now

  local monitors = runtime.refs.monitor_mgr:scan()
  local signature = monitor_signature(monitors)
  local monitor_cache = runtime.state.monitor_cache
  local changed = (monitor_cache.signature ~= signature)

  if not changed and not force then
    runtime.log(("Monitor refresh unchanged: count=%d"):format(#monitors), "DEBUG")
    return
  end

  local prev_by_id = {}
  for _, old in ipairs(monitor_cache.list or {}) do prev_by_id[old.id or old.name] = old end

  local healthy = {}
  for _, entry in ipairs(monitors) do
    local id = entry.id or entry.name
    local prev = prev_by_id[id]
    local is_new = prev == nil
    if is_new or force then
      local ok, err = pcall(runtime.libs.ui.clear, entry.mon)
      if not ok then
        runtime.log("Disabling monitor " .. tostring(entry.name or id) .. " during clear-on-bind: " .. tostring(err), "WARN")
      else
        healthy[#healthy + 1] = entry
      end
    else
      healthy[#healthy + 1] = entry
    end
  end

  monitor_cache.list = healthy
  monitor_cache.signature = monitor_signature(healthy)
  runtime.log(("Monitor refresh changed=%s force=%s scanned=%d healthy=%d"):format(tostring(changed), tostring(force == true), #monitors, #healthy), "INFO")

  for _, entry in ipairs(healthy) do
    local prev = prev_by_id[entry.id or entry.name]
    local scale_changed = not prev or tostring(prev.text_scale) ~= tostring(entry.text_scale)
    local size_changed = not prev or tostring(prev.width) ~= tostring(entry.width) or tostring(prev.height) ~= tostring(entry.height)
    local layout_changed = not prev or tostring(prev.layout_class) ~= tostring(entry.layout_class)
    runtime.log(("Monitor delta: id=%s name=%s scale=%s size=%s layout=%s"):format(
      tostring(entry.id or "?"),
      tostring(entry.name or "?"),
      scale_changed and "changed" or "unchanged",
      size_changed and "changed" or "unchanged",
      layout_changed and "changed" or "unchanged"
    ), "INFO")
  end
end

return M
