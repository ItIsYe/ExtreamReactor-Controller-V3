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
local manifest = read("xreactor/installer_manifest.lua")
local stage = read("xreactor/installer_stage.lua")
local storage = read("xreactor/installer_storage.lua")

local required_snippets = {
  installer = {
    "STAGE_ROOT = \"/xreactor_stage\"",
    "local installer_main = dofile(\"/xreactor/installer_main.lua\")"
  },
  storage = {
    "function M.preflight_storage(ctx, storage_plan, opts)",
    "Storage preflight OK (mode=%s free=%d payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)",
    "Not enough free space (mode=%s free=%d payload=%d growth=%d stage_peak=%d buffer=%d+%d+%d required=%d)"
  },
  manifest = {
    "if entry.always == true or M.role_matches(entry.required_for, role_label) then",
    "if entry.path and (include_dev_files or not M.should_exclude_prod_path(entry.path)) then"
  },
  stage = {
    "function M.activate_stage(ctx)",
    "Stage activation failed; attempting rollback"
  }
}

for _, snippet in ipairs(required_snippets.installer) do
  if not installer:find(snippet, 1, true) then
    error("installer missing conservative strategy snippet: " .. snippet)
  end
end
for _, snippet in ipairs(required_snippets.storage) do
  if not storage:find(snippet, 1, true) then
    error("storage module missing conservative strategy snippet: " .. snippet)
  end
end
for _, snippet in ipairs(required_snippets.manifest) do
  if not manifest:find(snippet, 1, true) then
    error("manifest module missing conservative strategy snippet: " .. snippet)
  end
end
for _, snippet in ipairs(required_snippets.stage) do
  if not stage:find(snippet, 1, true) then
    error("stage module missing conservative strategy snippet: " .. snippet)
  end
end

print("installer_conservative_strategy_test.lua: ok")
