local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local main = read("xreactor/installer_main.lua")
local storage = read("xreactor/installer_storage.lua")

local main_checks = {
  "function ctx.set_log_target(role_label, node_label)",
  "installer_%s_%s.log",
  "installer_%s.log",
  "ctx.set_log_target(role.label, node_id)",
  "ctx.set_log_target(role_label, node_id)"
}

for _, snippet in ipairs(main_checks) do
  if not main:find(snippet, 1, true) then
    error("installer log naming missing snippet: " .. snippet)
  end
end

if not storage:find("name:match(\"^installer_.+%%.log%%.1$\")", 1, true) then
  error("installer storage rotation guard missing installer role log pattern")
end

print("installer_log_naming_test.lua: ok")
