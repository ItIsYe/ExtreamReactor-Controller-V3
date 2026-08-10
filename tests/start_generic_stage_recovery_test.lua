local function read_file(path)
  local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local function extract(src, a, b)
  local i = assert(src:find(a, 1, true)); local j = assert(src:find(b, i, true)); return src:sub(i, j - 1)
end
local root = os.getenv("REPO_ROOT") or "."
local src = read_file(root .. "/xreactor/start.lua")
local snippet = extract(src, "local function crc32_hex", "-- Kontrollierter Resume:")
local chunk = assert(load([[local INSTALL_ROOT="/xreactor"
]] .. snippet .. [[
return recover_staged_files
]], "=stage_recovery", "t"))
local recover = chunk()

local function fs_mock(initial)
  local files = {}; for k,v in pairs(initial or {}) do files[k]=v end
  return {
    files = files,
    exists = function(p) return files[p] ~= nil end,
    open = function(p, mode)
      if mode ~= "r" or files[p] == nil then return nil end
      return { readAll=function() return files[p] end, close=function() end }
    end,
    move = function(a,b) assert(files[a] ~= nil); files[b]=files[a]; files[a]=nil end,
    getDir = function(p) return p:match("^(.*)/[^/]+$") or "" end,
    makeDir = function() end,
  }
end

local good = "return { ok = true }\n"
local meta = { size_bytes = 21, hash = "6378232e" }

do
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_tmp"] = good })
  _G.fs = fsx
  local ok, errors = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(ok and #errors == 0 and fsx.files["/xreactor/core/a.lua"] == good, "valid tmp must be promoted")
end

do
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_tmp"] = good .. "x" })
  _G.fs = fsx
  local ok = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(not ok and fsx.files["/xreactor/core/a.lua"] == nil, "CRC/size-mismatched tmp must never be promoted")
end

do
  local old = "return { old = true }\n"
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_prev"] = old })
  _G.fs = fsx
  local ok = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(not ok, "old previous copy is rollback material, not proof that new install is current")
  assert(fsx.files["/xreactor/core/a.lua"] == old, "readable previous copy must restore a missing main file")
end

print("start_generic_stage_recovery_test.lua: ok")
