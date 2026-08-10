local function read_file(path)
  local f = assert(io.open(path, "r")); local s=f:read("*a"); f:close(); return s
end
local root = os.getenv("REPO_ROOT") or "."
local installer = read_file(root .. "/installer")
local init = read_file(root .. "/xreactor/installer/init.lua")
local start = read_file(root .. "/xreactor/start.lua")
local journal = read_file(root .. "/xreactor/installer/journal.lua")
assert(installer:find("__xreactor_forced_ref", 1, true), "bootstrap must accept forced immutable recovery ref")
assert(start:find("Original-Ref nicht rekonstruierbar", 1, true), "fallback recovery policy must be explicit in boot log")
for _, token in ipairs({"resolved_commit_sha", "installed_at", "manifest_id", "installer_ref", "recovery_origin_ref"}) do
  assert(init:find(token, 1, true), "install metadata missing field " .. token)
end
assert(journal:find("expected_meta", 1, true), "journal must carry per-file recovery metadata")
print("installer_resolved_commit_metadata_test.lua: ok")
