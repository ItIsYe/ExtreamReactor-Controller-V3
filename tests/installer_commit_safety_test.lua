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
  "local function preflight_storage(storage_plan, allow_cleanup)",
  "warn(\"Storage preflight result: not ok\")",
  "local function stage_expected_files(expected)",
  "if fs.exists(STAGE_ROOT) then\n        fs.delete(STAGE_ROOT)\n      end\n      return false, \"Download failed: \" .. tostring(err)",
  "local function activate_stage()",
  "fs.move(INSTALL_ROOT, BACKUP_ROOT)",
  "local moved = pcall(fs.move, STAGE_ROOT, INSTALL_ROOT)",
  "warn(\"Stage activation failed; attempting rollback\")",
  "if fs.exists(BACKUP_ROOT) then\n      fs.move(BACKUP_ROOT, INSTALL_ROOT)\n    end"
}

for _, snippet in ipairs(required) do
  if not installer:find(snippet, 1, true) then
    error("missing commit safety snippet: " .. snippet)
  end
end

print("installer_commit_safety_test.lua: ok")
