-- tests/sim_fs_contract_test.lua
local fs_mod = dofile("tests/sim/cc/fs.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

local fs = fs_mod.new()

-- open/write/close/read
local f = fs.open("/test.lua", "w")
T(f ~= nil, "open w")
f.write("hello world\n")
f.write("line2")
f.close()

T(fs.exists("/test.lua"), "exists")
A(fs.getSize("/test.lua"), #"hello world\nline2", "size")

local r = fs.open("/test.lua", "r")
T(r ~= nil, "open r")
A(r.readAll(), "hello world\nline2", "readAll")
r.close()

-- readLine
local r2 = fs.open("/test.lua", "r")
A(r2.readLine(), "hello world", "line1")
A(r2.readLine(), "line2", "line2")
A(r2.readLine(), nil, "eof")
r2.close()

-- append
local a = fs.open("/test.lua", "a")
a.write(" appended"); a.close()
local r3 = fs.open("/test.lua", "r")
T(r3.readAll():find("appended") ~= nil, "append")
r3.close()

-- list
fs.open("/dir/a.lua","w").close()
fs.open("/dir/b.lua","w").close()
local lst = fs.list("/dir")
A(#lst, 2, "list count")
A(lst[1], "a.lua", "sorted")

-- delete
fs.delete("/test.lua")
T(not fs.exists("/test.lua"), "deleted")

-- combine/getName/getDir
A(fs.combine("a", "b"), "a/b", "combine")
A(fs.combine("/x", "y"), "/x/y", "combine abs")
A(fs.getName("/foo/bar.lua"), "bar.lua", "getName")
A(fs.getDir("/foo/bar.lua"), "/foo", "getDir")

-- move/copy
fs._set("/src.lua", "content")
fs.copy("/src.lua", "/dst.lua")
T(fs.exists("/dst.lua"), "copy")
fs.move("/dst.lua", "/moved.lua")
T(not fs.exists("/dst.lua"), "move src gone")
T(fs.exists("/moved.lua"), "move dst exists")

print("sim_fs_contract_test.lua: ok")
