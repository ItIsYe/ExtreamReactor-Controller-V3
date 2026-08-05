-- tests/sim_term_contract_test.lua
local term_mod = dofile("tests/sim/cc/term.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

local t = term_mod.new({ width=20, height=5 })
local w, h = t.getSize()
A(w, 20, "width"); A(h, 5, "height")

-- write
t.setCursorPos(1,1)
t.write("Hello")
local row = t._row(1)
T(row:sub(1,5) == "Hello", "write")

-- clear
t.clear()
A(t._row(1):sub(1,5), "     ", "clear")

-- setCursorPos / getCursorPos
t.setCursorPos(3, 2)
local cx, cy = t.getCursorPos()
A(cx, 3, "cx"); A(cy, 2, "cy")

-- clearLine
t.setCursorPos(1,2); t.write("xxxxxx")
t.clearLine()
A(t._row(2):sub(1,6), "      ", "clearLine")

-- scroll
t.setCursorPos(1,1); t.write("line1")
t.setCursorPos(1,2); t.write("line2")
t.scroll(1)
T(t._row(1):sub(1,5) == "line2", "scroll")

-- isColor
T(t.isColor(), "isColor")
T(t.isColour(), "isColour")

print("sim_term_contract_test.lua: ok")
