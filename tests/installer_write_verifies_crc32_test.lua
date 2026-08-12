-- tests/installer_write_verifies_crc32_test.lua
--
-- INSTALL-P0 (docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md,
-- Abschnitt 15): installer/stage.lua's M.verify() prüfte bisher nur
-- Existenz, Lesbarkeit, Größe und (bei .lua-Dateien) Syntax -- eine Datei
-- mit korrekter Größe und gültiger Syntax, aber verändertem Inhalt, wurde
-- akzeptiert, obwohl das Manifest einen CRC32-Hash dafür bereitstellt.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local function make_fake_fs()
  local files = {}
  local dirs = { ["/"] = true }
  local fake = {}
  fake.exists = function(p) return files[p] ~= nil or dirs[p] == true end
  fake.isDir = function(p) return dirs[p] == true end
  fake.getDir = function(p)
    local d = p:match("^(.*)/[^/]+$")
    return d or ""
  end
  fake.list = function(p)
    local out = {}
    for k in pairs(files) do
      if k:sub(1, #p + 1) == p .. "/" then out[#out + 1] = k:sub(#p + 2) end
    end
    return out
  end
  fake.makeDir = function(p) dirs[p] = true end
  fake.delete = function(p) files[p] = nil; dirs[p] = nil end
  fake.move = function(src, dst)
    if files[src] == nil then error("move: no such file " .. src) end
    files[dst] = files[src]
    files[src] = nil
  end
  fake.open = function(p, mode)
    if mode == "r" then
      if files[p] == nil then return nil end
      local content = files[p]
      return { readAll = function() return content end, close = function() end }
    elseif mode == "w" then
      local buf = {}
      return {
        write = function(s) buf[#buf + 1] = s end,
        close = function() files[p] = table.concat(buf) end,
      }
    end
  end
  return fake, files
end

local function load_module(path, env)
  local src = read(path)
  local fn = assert(load(src, "=" .. path, "t", env))
  return fn()
end

local function load_manifest_mod()
  -- M.crc32 is pure and needs no CC:Tweaked globals at all.
  local env = setmetatable({}, { __index = _G })
  return load_module("xreactor/installer/manifest.lua", env)
end

local manifest_mod = load_manifest_mod()
local GOOD_CONTENT = "return { role = \"RT\" }\n"
local GOOD_HASH = manifest_mod.crc32(GOOD_CONTENT)
-- Same length as GOOD_CONTENT, different bytes -- a corrupted transfer
-- that size-only verification would never catch.
local BAD_CONTENT = "return { role = \"XX\" }\n"
assert(#BAD_CONTENT == #GOOD_CONTENT, "test fixture must keep matching lengths")

local function new_stage_mod()
  local fake_fs, files = make_fake_fs()
  local env = setmetatable({
    fs = fake_fs,
    os = { sleep = function() end, epoch = function() return 0 end },
  }, { __index = _G })
  local stage_mod = load_module("xreactor/installer/stage.lua", env)
  return stage_mod, files
end

-- ---------------------------------------------------------------------
-- 1) M.verify(): correct content passes, corrupted-but-same-size content
--    must be rejected once a crc32_fn is supplied.
-- ---------------------------------------------------------------------
do
  local stage_mod = new_stage_mod()
  local entry = { size_bytes = #GOOD_CONTENT, hash = GOOD_HASH }

  local ok_w = stage_mod.write("/xreactor/config/role.lua", GOOD_CONTENT)
  assert(ok_w, "write of good content must succeed")
  local ok_v = stage_mod.verify("/xreactor/config/role.lua", entry, manifest_mod.crc32)
  assert(ok_v == true, "verify() must accept content matching size and hash")

  local ok_w2 = stage_mod.write("/xreactor/config/role.lua", BAD_CONTENT)
  assert(ok_w2, "write of corrupted (same-size) content must succeed at the fs layer")
  local ok_v2, err_v2 = stage_mod.verify("/xreactor/config/role.lua", entry, manifest_mod.crc32)
  assert(ok_v2 == false,
    "verify() must reject content with correct size but wrong CRC32 hash -- got accepted")
  assert(tostring(err_v2):find("hash", 1, true),
    "verify() failure reason should mention the hash mismatch: " .. tostring(err_v2))
end

-- ---------------------------------------------------------------------
-- 2) M.install(): a download that always returns corrupted (same-size)
--    content must fail overall once a crc32_fn is supplied, instead of
--    silently accepting the corrupted file after exhausting retries.
-- ---------------------------------------------------------------------
do
  local stage_mod = new_stage_mod()
  local fake_http = {
    download_file = function() return BAD_CONTENT end,
    is_html = function() return false end,
  }
  local entry = { size_bytes = #GOOD_CONTENT, hash = GOOD_HASH }
  local files = { { path = "config/role.lua", entry = entry } }

  local ok, err = stage_mod.install(files, "/xreactor", fake_http, "beta", nil, manifest_mod.crc32)
  assert(ok == false, "install() must fail when every download attempt returns hash-mismatched content")
  assert(tostring(err):find("hash", 1, true), "install() failure reason should mention the hash mismatch: " .. tostring(err))
end

-- ---------------------------------------------------------------------
-- 3) Wiring: installer/init.lua (seit INSTALL-P1/Abschnitt 8 die EINZIGE
--    Stelle mit tatsaechlicher Installationslogik -- /installer ist nur
--    noch ein duenner Bootstrap ohne eigene stage_mod.install()-Aufrufe,
--    siehe installer_bootstrap_test.lua) muss manifest_mod.crc32 in
--    stage_mod.install() durchreichen, damit M.verify() tatsaechlich
--    einen crc32_fn erhaelt.
-- ---------------------------------------------------------------------
do
  local init_src = read("xreactor/installer/init.lua")
  assert(init_src:find("stage_mod.install(file_list, INSTALL_ROOT, http_mod, ref,", 1, true),
    "installer/init.lua must still call stage_mod.install with ref")
  assert(init_src:find("manifest_mod.crc32)", 1, true),
    "installer/init.lua must pass manifest_mod.crc32 into stage_mod.install()")
end

print("installer_write_verifies_crc32_test.lua: ok")
