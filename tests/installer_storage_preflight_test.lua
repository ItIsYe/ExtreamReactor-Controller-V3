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
  "local function estimate_required_storage(expected)",
  "payload_bytes = total",
  "fixed_buffer_bytes = STORAGE_BUFFER_BYTES",
  "percent_buffer_bytes = percent_buffer",
  "Storage low before install/update (free=%d payload=%d buffer=%d+%d required=%d)",
  "cleanup_stage_and_logs(true)"
}

for _, snippet in ipairs(required) do
  if not installer:find(snippet, 1, true) then
    error("missing storage preflight snippet: " .. snippet)
  end
end

print("installer_storage_preflight_test.lua: ok")
