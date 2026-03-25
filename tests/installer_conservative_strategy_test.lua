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

local required_snippets = {
  "local STAGE_ROOT = \"/xreactor_stage\"",
  "local function preflight_storage(storage_plan, allow_cleanup)",
  "Storage preflight OK (free=%d payload=%d buffer=%d+%d required=%d)",
  "Not enough free space (free=%d payload=%d buffer=%d+%d required=%d)",
  "if entry.always == true or role_matches(entry.required_for, role_label) then",
  "local function activate_stage()",
  "Stage activation failed; attempting rollback",
  "if fs.exists(STAGE_ROOT) then\n      fs.delete(STAGE_ROOT)\n    end\n    return false, \"Download failed: \" .. tostring(err)",
  "if entry.path and (INCLUDE_DEV_FILES or not should_exclude_prod_path(entry.path)) then"
}

for _, snippet in ipairs(required_snippets) do
  if not installer:find(snippet, 1, true) then
    error("installer missing required conservative strategy snippet: " .. snippet)
  end
end

print("installer_conservative_strategy_test.lua: ok")
