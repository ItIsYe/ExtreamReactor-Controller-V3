local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local main = read("xreactor/installer_main.lua")
local stage = read("xreactor/installer_stage.lua")

local main_snippets = {
  "ctx.release_metadata_body = body",
  "local function enforce_release_metadata_strategy(ctx, expected)",
  "Manifest expected files missing release.lua in beta install strategy",
  "Release metadata body missing before stage download in beta install strategy",
  "enforce_release_metadata_strategy(ctx, expected)"
}

for _, snippet in ipairs(main_snippets) do
  if not main:find(snippet, 1, true) then
    error("installer main missing beta release metadata guard snippet: " .. snippet)
  end
end

local stage_snippets = {
  "if entry.path == \"release.lua\" and ctx.source_ref == \"beta\" then",
  "Reusing cached release metadata for release.lua in beta install strategy",
  "Beta release metadata cache missing for release.lua",
  "cached release metadata size mismatch for %s (expected=%s actual=%s)",
  "cached release metadata hash mismatch for %s (expected=%s actual=%s)",
  "ok, err = ctx.write_file(target_path, ctx.release_metadata_body)"
}

for _, snippet in ipairs(stage_snippets) do
  if not stage:find(snippet, 1, true) then
    error("installer stage missing beta release metadata snippet: " .. snippet)
  end
end

print("installer_beta_release_metadata_reuse_guard_test.lua: ok")
