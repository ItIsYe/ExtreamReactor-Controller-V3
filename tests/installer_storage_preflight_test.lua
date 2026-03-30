local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local installer = read("installer")

local required = {
  "local function estimate_required_storage(expected, mode)",
  "payload_bytes = total",
  "stage_peak_bytes = stage_peak_bytes",
  "estimate_base_bytes = estimate_base",
  "fixed_buffer_bytes = buffer_base",
  "percent_buffer_bytes = percent_buffer",
  "churn_buffer_bytes = churn_buffer",
  "Storage low before install/update (mode=%s free=%d payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
  "cleanup_stage_and_logs(cleanup_logs, cleanup_backup)"
}

for _, snippet in ipairs(required) do
  if not installer:find(snippet, 1, true) then
    error("missing storage preflight snippet: " .. snippet)
  end
end

print("installer_storage_preflight_test.lua: ok")
