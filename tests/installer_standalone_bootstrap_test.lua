local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local source = read("installer")

local required = {
  "ensure_installer_runtime",
  "installer_main.lua",
  "installer_http.lua",
  "installer_manifest.lua",
  "installer_stage.lua",
  "installer_startup.lua",
  "installer_storage.lua"
}

for _, snippet in ipairs(required) do
  if not source:find(snippet, 1, true) then
    error("standalone bootstrap missing snippet: " .. snippet)
  end
end

print("installer_standalone_bootstrap_test.lua: ok")
