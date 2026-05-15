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
    runtime.log(("Monitor refresh unchanged: count=%d signature=%s"):format(#monitors, signature), "DEBUG")
    return
  end

  local prev_by_id = {}
  for _, old in ipairs(monitor_cache.list or {}) do prev_by_id[old.id or old.name] = old end

  local healthy = {}
  for _, entry in ipairs(monitors) do
    local id = entry.id or entry.name
    local is_new = prev_by_id[id] == nil
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
    runtime.log(("Monitor state: id=%s name=%s size=%sx%s layout=%s text_scale=%s applied_scale=%s"):format(
      tostring(entry.id or "?"), tostring(entry.name or "?"), tostring(entry.width or "?"), tostring(entry.height or "?"), tostring(entry.layout_class or "?"), tostring(entry.text_scale or "?"), tostring(entry.last_applied_scale or "?")
    ), "INFO")
  end
end

return M
