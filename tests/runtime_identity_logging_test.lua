local function read(path)
  local file = io.open(path, "r")
  if not file then
    error("failed to read " .. tostring(path))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local start_lua = read("xreactor/start.lua")
if not start_lua:find("Starting XReactor role=%%s release=%%s manifest=%%s", 1, true) then
  error("startup identity log format missing")
end

local release_lua = read("xreactor/release.lua")
if not release_lua:find("manifest_id", 1, true) then
  error("release.lua missing manifest_id")
end
if not release_lua:find("release_id", 1, true) then
  error("release.lua missing release_id")
end

print("runtime_identity_logging_test.lua: ok")
