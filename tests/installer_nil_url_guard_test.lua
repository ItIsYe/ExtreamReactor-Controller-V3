local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local installer_core = read("installer")
local installer_http = read("xreactor/installer_http.lua")
local installer_main = read("xreactor/installer_main.lua")

local required = {
  { source = installer_core, snippet = "if type(url) ~= \"string\" or url == \"\" then" },
  { source = installer_core, snippet = "return nil, \"invalid url\"" },
  { source = installer_http, snippet = "if type(url) ~= \"string\" or url == \"\" then" },
  { source = installer_http, snippet = "return nil, \"invalid url\"" },
  { source = installer_main, snippet = "return nil, \"manifest url missing\"" },
  { source = installer_main, snippet = "return false, \"release metadata url missing\"" }
}

for _, check in ipairs(required) do
  if not check.source:find(check.snippet, 1, true) then
    error("missing installer nil-url guard snippet: " .. tostring(check.snippet))
  end
end

print("installer_nil_url_guard_test.lua: ok")
