local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local source = read("xreactor/installer_main.lua")

local required = {
  "release_url = constants.RELEASE_URL",
  "release metadata url missing (mode=%s role=%s)",
  "Release metadata URL missing; derived from BASE_URL",
  "Downloading release metadata from %s (mode=%s role=%s)"
}

for _, snippet in ipairs(required) do
  if not source:find(snippet, 1, true) then
    error("missing installer release-url resolution guard snippet: " .. tostring(snippet))
  end
end

print("installer_release_url_resolution_test.lua: ok")
