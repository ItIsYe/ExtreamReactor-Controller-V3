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
local main = read("xreactor/installer_main.lua")

local required_stage = {
  "function M.stage_expected_files(ctx, expected)",
  "local target_path = ctx.constants.STAGE_ROOT .. \"/\" .. entry.path",
  "return false, \"Download failed: \" .. tostring(err)",
  "function M.verify_stage(ctx, expected)",
  "local moved = pcall(ctx.fs.move, ctx.constants.STAGE_ROOT, ctx.constants.INSTALL_ROOT)"
}

for _, snippet in ipairs(required_stage) do
  if not stage:find(snippet, 1, true) then
    error("missing stage install snippet: " .. snippet)
  end
end

if not main:find("stage_and_verify(ctx, expected)", 1, true) then
  error("installer main missing stage_and_verify orchestration")
end

print("installer_stage_install_behavior_test.lua: ok")
