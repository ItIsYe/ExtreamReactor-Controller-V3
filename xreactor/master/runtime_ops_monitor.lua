local M = {}

function M.refresh_monitors(runtime, force)
  local now = os.epoch("utc")
  if not runtime.refs.monitor_mgr then
    return
  end
  if not force and now - runtime.state.monitor_scan_last < 5000 then
    return
  end
  runtime.state.monitor_scan_last = now
  local monitors = runtime.refs.monitor_mgr:scan()
  local signature_parts = {}
  for _, entry in ipairs(monitors) do
    table.insert(signature_parts, entry.id or entry.name)
  end
  local signature = table.concat(signature_parts, "|")
  local monitor_cache = runtime.state.monitor_cache
  if monitor_cache.signature ~= signature or force then
    local healthy = {}
    for _, entry in ipairs(monitors) do
      local ok, err = pcall(runtime.libs.ui.clear, entry.mon)
      if ok then
        table.insert(healthy, entry)
      else
        runtime.log("Disabling monitor " .. tostring(entry.name or entry.id) .. " during initial clear: " .. tostring(err), "WARN")
      end
    end
    local healthy_signature_parts = {}
    for _, entry in ipairs(healthy) do
      table.insert(healthy_signature_parts, entry.id or entry.name)
    end
    monitor_cache.list = healthy
    monitor_cache.signature = table.concat(healthy_signature_parts, "|")
    runtime.log(("Monitor refresh: scanned=%d healthy=%d force=%s"):format(#monitors, #healthy, tostring(force == true)), "INFO")
    if #healthy < #monitors then
      runtime.log(("UI degraded: %d/%d monitors available after clear guard"):format(#healthy, #monitors), "WARN")
    end
  end
end

return M
