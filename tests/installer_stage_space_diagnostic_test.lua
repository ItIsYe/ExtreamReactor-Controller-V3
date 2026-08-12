-- tests/installer_stage_space_diagnostic_test.lua
--
-- Regression test: when installer/stage.lua's M.write() runs out of disk
-- space, the previous error ("not enough space for <path>") gave the user
-- nothing actionable on a reinstall of an already-running node -- /xreactor
-- is deleted before new files are written (see installer/init.lua), so the
-- shortfall is essentially always something OUTSIDE /xreactor, most
-- commonly accumulated /xreactor_logs. The error must now report the
-- free/needed byte counts and, when /xreactor_logs exists and is non-empty,
-- its measured size -- so the user knows what to clear manually. The
-- installer itself must still never delete /xreactor_logs.

local files = {}
local dirs = { ["/xreactor_logs"] = true }
local deleted = {}

_G.fs = {
  getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
  exists = function(p) return files[p] ~= nil or dirs[p] == true end,
  isDir = function(p) return dirs[p] == true end,
  makeDir = function(p) dirs[p] = true end,
  getFreeSpace = function() return 100 end,
  getSize = function(p) return files[p] and #files[p] or 0 end,
  list = function(p)
    if p ~= "/xreactor_logs" then return {} end
    local names = {}
    for path in pairs(files) do
      local prefix = "/xreactor_logs/"
      if path:sub(1, #prefix) == prefix then
        names[#names + 1] = path:sub(#prefix + 1)
      end
    end
    return names
  end,
  open = function(p, mode)
    if mode == "w" then
      local buf = {}
      return {
        write = function(content) buf[#buf + 1] = content end,
        close = function() files[p] = table.concat(buf) end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
  delete = function(p) files[p] = nil; deleted[p] = true end,
  move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
}

files["/xreactor_logs/master.log"] = string.rep("x", 500)

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
local stage = require("installer.stage")

local ok, err = stage.write("/xreactor/config/role.lua", string.rep("y", 1000))

if ok then
  error("expected write to fail when free space is insufficient, got ok=true")
end
local msg = tostring(err)
if not msg:find("not enough space", 1, true) then
  error("expected 'not enough space' in error, got: " .. msg)
end
if not msg:find("free=100", 1, true) then
  error("expected reported free-space figure in error, got: " .. msg)
end
if not msg:find("xreactor_logs", 1, true) then
  error("expected /xreactor_logs mentioned as the likely reclaimable space, got: " .. msg)
end
if not msg:find("500", 1, true) then
  error("expected measured /xreactor_logs size (500 bytes) in error, got: " .. msg)
end
if deleted["/xreactor_logs/master.log"] then
  error("CRITICAL: installer must never delete /xreactor_logs itself, only report its size")
end

print("installer_stage_space_diagnostic_test.lua: ok")
