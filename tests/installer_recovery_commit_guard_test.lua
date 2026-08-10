local f = assert(io.open("xreactor/installer/init.lua", "r"))
local src = f:read("*a"); f:close()

assert(src:find("using_existing_recovery_backup", 1, true),
  "installer retry must distinguish an existing recovery backup")
assert(src:find("VALID_INCOMPLETE", 1, true),
  "installer retry must detect incomplete previous transaction")
assert(src:find("verwende unveraendert das bestehende Recovery%-Backup"),
  "installer retry must reuse original recovery backup")
assert(src:find("Installation wird NICHT als COMMITTED markiert", 1, true),
  "partial config restore must abort before COMMITTED")

local b = assert(io.open("installer", "r"))
local bootstrap = b:read("*a"); b:close()
assert(bootstrap:find("local ref = sha", 1, true))
assert(not bootstrap:find('local ref = sha or "beta"', 1, true),
  "bootstrap must not fall back to a moving branch ref")

print("installer_recovery_commit_guard_test: OK")
