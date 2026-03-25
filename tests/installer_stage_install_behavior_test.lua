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
  "local function stage_expected_files(expected)",
  "local target_path = STAGE_ROOT .. \"/\" .. entry.path",
  "return false, \"Download failed: \" .. tostring(err)",
  "local stage_ok, stage_err = verify_stage(expected)",
  "if not stage_ok then\n    fs.delete(STAGE_ROOT)\n    fatal(\"Staged validation failed: \" .. tostring(stage_err))\n  end",
  "local moved = pcall(fs.move, STAGE_ROOT, INSTALL_ROOT)"
}

for _, snippet in ipairs(required) do
  if not installer:find(snippet, 1, true) then
    error("missing stage install snippet: " .. snippet)
  end
end

print("installer_stage_install_behavior_test.lua: ok")
