local function load_table(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error("failed loading " .. tostring(path) .. ": " .. tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("failed executing " .. tostring(path) .. ": " .. tostring(result))
  end
  if type(result) ~= "table" then
    error("expected table from " .. tostring(path))
  end
  return result
end

local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local bootstrap = read("installer")
local main = read("xreactor/installer_main.lua")
local release = load_table("xreactor/release.lua")
local manifest = load_table("xreactor/manifest.lua")

if not bootstrap:find('BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/"', 1, true) then
  error("installer bootstrap must stay beta-only")
end
if not bootstrap:find("Installer source fixed to beta branch", 1, true) then
  error("installer bootstrap must announce beta-only source")
end

if not main:find("release metadata commit pin is not allowed in beta install strategy", 1, true) then
  error("installer main commit-pin beta guard missing")
end
if not main:find("release metadata source_ref is not allowed in beta install strategy", 1, true) then
  error("installer main source_ref beta guard missing")
end
if not main:find("Installer source fixed to beta branch", 1, true) then
  error("installer main must enforce beta install source")
end
if not main:find("Manifest source_ref must be beta during normal install/update", 1, true) then
  error("installer main must enforce manifest beta source_ref")
end

local commit_sha = release.commit_sha
if commit_sha ~= nil and commit_sha ~= "" and commit_sha ~= "beta" then
  error("release.commit_sha must be nil/empty/beta for beta-only installer strategy")
end
if tostring(release.source_ref or "") ~= "beta" then
  error("release.source_ref must be beta")
end
if tostring(manifest.source_ref or "") ~= "beta" then
  error("manifest.source_ref must be beta")
end
if tostring(release.source_ref or "") ~= tostring(manifest.source_ref or "") then
  error("release/manifest source_ref mismatch")
end

print("installer_release_pin_consistency_test.lua: ok")
