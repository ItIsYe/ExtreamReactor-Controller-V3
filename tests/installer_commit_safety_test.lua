local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local stage = read("xreactor/installer_stage.lua")

local required = {
  "function M.stage_expected_files(ctx, expected)",
  "if ctx.fs.exists(ctx.constants.STAGE_ROOT) then\n        ctx.fs.delete(ctx.constants.STAGE_ROOT)\n      end\n      return false, \"Download failed: \" .. tostring(err)",
  "function M.activate_stage(ctx)",
  "ctx.fs.move(ctx.constants.INSTALL_ROOT, ctx.constants.BACKUP_ROOT)",
  "local moved = pcall(ctx.fs.move, ctx.constants.STAGE_ROOT, ctx.constants.INSTALL_ROOT)",
  "ctx.warn(\"Stage activation failed; attempting rollback\")",
  "if ctx.fs.exists(ctx.constants.BACKUP_ROOT) then\n      ctx.fs.move(ctx.constants.BACKUP_ROOT, ctx.constants.INSTALL_ROOT)\n    end"
}

for _, snippet in ipairs(required) do
  if not stage:find(snippet, 1, true) then
    error("missing commit safety snippet: " .. snippet)
  end
end

print("installer_commit_safety_test.lua: ok")
