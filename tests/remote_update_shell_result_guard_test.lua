local f = assert(io.open("xreactor/core/remote_update.lua", "r"))
local src = f:read("*a"); f:close()

assert(src:find("result ~= false", 1, true),
  "shell.run false must be treated as installer failure")
assert(src:find("_G.__xreactor_remote_update = nil", 1, true),
  "remote-update mode must be cleared after installer attempt")
assert(src:find("message.command", 1, true),
  "legacy command token shape must remain supported")

print("remote_update_shell_result_guard_test: OK")
