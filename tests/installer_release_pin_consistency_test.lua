local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local bootstrap = read("installer")
local main = read("xreactor/installer_main.lua")

local bootstrap_checks = {
  "local function resolve_release_ref()",
  "local local_release_path = constants.INSTALL_ROOT .. \"/release.lua\"",
  "Installer source pinned to commit: ",
  "(release=",
}

for _, snippet in ipairs(bootstrap_checks) do
  if not bootstrap:find(snippet, 1, true) then
    error("installer bootstrap release consistency snippet missing: " .. snippet)
  end
end

local main_checks = {
  "Manifest source_ref mismatch (release source=%s manifest source_ref=%s)",
  "Manifest source_ref is mutable branch 'beta' while release pins %s",
}

for _, snippet in ipairs(main_checks) do
  if not main:find(snippet, 1, true) then
    error("installer main release consistency snippet missing: " .. snippet)
  end
end

print("installer_release_pin_consistency_test.lua: ok")
