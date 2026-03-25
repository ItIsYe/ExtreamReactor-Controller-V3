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
  "local function preflight_storage(required_bytes, allow_cleanup)",
  "if entry.always == true or role_matches(entry.required_for, role_label) then",
  "local function activate_stage()",
  "Stage activation failed; attempting rollback"
}

for _, snippet in ipairs(required_snippets) do
  if not installer:find(snippet, 1, true) then
    error("installer missing required conservative strategy snippet: " .. snippet)
  end
end

print("installer_conservative_strategy_test.lua: ok")
