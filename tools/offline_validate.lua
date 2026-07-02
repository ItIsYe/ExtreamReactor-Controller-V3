-- XReactor offline repository validator.
-- Runs outside Minecraft/CC:Tweaked. It only checks repository consistency.

local failures = 0

local function fail(msg)
  failures = failures + 1
  io.stderr:write("FAIL: " .. tostring(msg) .. "\n")
end

local function ok(msg)
  io.stdout:write("OK: " .. tostring(msg) .. "\n")
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function load_table(path)
  local loader, err = loadfile(path)
  if not loader then
    fail("lua parse failed: " .. path .. " :: " .. tostring(err))
    return nil
  end
  local ok_run, value = pcall(loader)
  if not ok_run then
    fail("lua load failed: " .. path .. " :: " .. tostring(value))
    return nil
  end
  if type(value) ~= "table" then
    fail("expected table from: " .. path)
    return nil
  end
  return value
end

local function check_parse(path)
  local loader, err = loadfile(path)
  if not loader then fail("lua parse failed: " .. path .. " :: " .. tostring(err)) end
end

local function shell_lines(cmd)
  local p = io.popen(cmd)
  local out = {}
  if not p then return out end
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  table.sort(out)
  return out
end

-- Fix (2026-07-01, repo hygiene): die 6 losen installer_*.lua-Dateien im
-- Repo-Root existierten seit dem Umbau auf den monolithischen `installer`
-- nicht mehr in der aktiven Codepath — sie waren nirgends mehr required()/
-- dofile()'d, nur noch tote Verweise im Manifest. Wurden geloescht. Diese
-- required-Liste pruefte bisher ihre Existenz und wuerde das jetzt bewusst
-- richtige Fehlen als Fehler melden — korrigiert.
local required = {
  "installer",
  "xreactor/start.lua",
  "xreactor/manifest.lua",
  "xreactor/release.lua",
}

for _, path in ipairs(required) do
  if exists(path) then ok("exists " .. path) else fail("missing required file: " .. path) end
end

check_parse("installer")
for _, path in ipairs(shell_lines("find xreactor -type f -name '*.lua'")) do
  check_parse(path)
end

local release = load_table("xreactor/release.lua")
local manifest = load_table("xreactor/manifest.lua")

if release and manifest then
  if tostring(release.source_ref or "") ~= tostring(manifest.source_ref or "") then
    fail("release/manifest source_ref mismatch")
  end
  if tostring(release.manifest_id or "") ~= tostring(manifest.manifest_id or "") then
    fail("release/manifest manifest_id mismatch")
  end
  if tonumber(release.manifest_version) ~= tonumber(manifest.manifest_version) then
    fail("release/manifest manifest_version mismatch")
  end
  ok("release and manifest metadata match")
end

local forbidden = {
  ["nodes/rt/commands.lua"] = true,
  ["nodes/rt/controllers.lua"] = true,
  ["nodes/rt/discovery.lua"] = true,
  ["nodes/rt/ramp.lua"] = true,
  ["nodes/rt/safety.lua"] = true,
  ["nodes/rt/state.lua"] = true,
  ["nodes/rt/telemetry.lua"] = true,
  ["nodes/energy/adapter_probe.lua"] = true,
}

local function check_manifest_entry(entry, source)
  if type(entry) == "string" then entry = { path = entry } end
  if type(entry) ~= "table" then return end
  local path = entry.path
  if type(path) ~= "string" or path == "" then
    fail("invalid manifest entry in " .. tostring(source))
    return
  end
  if forbidden[path] then
    fail("forbidden legacy manifest path: " .. path)
  end
  if not exists("xreactor/" .. path) then
    fail("manifest path missing in repo: " .. path)
  end
end

if manifest then
  for _, entry in ipairs(manifest.base_files or {}) do
    check_manifest_entry(entry, "base_files")
  end
  for role, list in pairs(manifest.roles or {}) do
    for _, entry in ipairs(list or {}) do
      check_manifest_entry(entry, "role " .. tostring(role))
    end
  end
  ok("manifest file references checked")
end

-- Runtime-generated files that are written by the installer and intentionally
-- absent from the repository. start.lua references them by path but they only
-- exist after a successful installation.
local RUNTIME_GENERATED = {
  ["/xreactor/config/role.lua"] = true,
  ["/xreactor/config/node_id.txt"] = true,
}

local start_body = read_all("xreactor/start.lua") or ""
for quoted in start_body:gmatch('"(/xreactor/[^"]+%.lua)"') do
  if RUNTIME_GENERATED[quoted] then
    ok("start.lua runtime-generated (expected absent): " .. quoted)
  else
    local rel = quoted:gsub("^/xreactor/", "xreactor/")
    if not exists(rel) then
      fail("start.lua references missing file: " .. quoted)
    end
  end
end
ok("start.lua entrypoint references checked")

if failures > 0 then
  io.stderr:write("\nOffline validation failed: " .. failures .. " problem(s)\n")
  os.exit(1)
end

io.stdout:write("\nOffline validation OK\n")
