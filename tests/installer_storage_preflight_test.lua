local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local storage = read("xreactor/installer_storage.lua")

local required = {
  "function M.estimate_required_storage(fs_api, install_root, expected, mode, constants)",
  "payload_bytes = total",
  "stage_peak_bytes = stage_peak_bytes",
  "estimate_base_bytes = estimate_base",
  "fixed_buffer_bytes = buffer_base",
  "percent_buffer_bytes = percent_buffer",
  "growth_buffer_bytes = update_growth_buffer",
  "Storage low before install/update (mode=%s free=%s payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
  "trimmed == \"unlimited\"",
  "M.cleanup_stage_and_logs(ctx, opts)",
  "Storage cleanup reclaimed bytes: stage=%d backup=%d logs=%d rotated=%d temp=%d"
}

for _, snippet in ipairs(required) do
  if not storage:find(snippet, 1, true) then
    error("missing storage preflight snippet: " .. snippet)
  end
end

print("installer_storage_preflight_test.lua: ok")
