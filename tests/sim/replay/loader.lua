-- tests/sim/replay/loader.lua  Phase 8.2
-- Lädt Trace-Fixtures und stellt sie als Replay-Source bereit.

local M = {}

-- Fixture aus Lua-String laden
function M.from_string(s)
  local fn = load("return " .. s) or load(s)
  if not fn then error("invalid fixture: cannot parse") end
  local ok, trace = pcall(fn)
  if not ok then error("fixture load error: " .. tostring(trace)) end
  M.validate(trace)
  return trace
end

-- Fixture aus Datei laden (CC:Tweaked fs oder io)
function M.from_file(path, fs_or_io)
  local content
  if fs_or_io and fs_or_io.open then
    local f = fs_or_io.open(path, "r")
    if not f then error("cannot open fixture: " .. path) end
    content = f.readAll(); f.close()
  else
    local f = io.open(path, "r")
    if not f then error("cannot open fixture: " .. path) end
    content = f:read("*a"); f:close()
  end
  return M.from_string(content)
end

function M.validate(trace)
  assert(type(trace) == "table", "trace must be table")
  assert(type(trace.entries) == "table", "trace.entries required")
  trace.format_version = trace.format_version or 1
  trace.ticks          = trace.ticks          or 0
  trace.dropped        = trace.dropped        or 0
  return trace
end

-- Iterator: Entries nach Kind filtern
function M.iter(trace, kind_filter)
  local i = 0
  return function()
    i = i + 1
    while i <= #trace.entries do
      local e = trace.entries[i]
      if not kind_filter or e.kind == kind_filter then
        return e
      end
      i = i + 1
    end
  end
end

-- Alle Entries eines Typs als Liste
function M.filter(trace, kind)
  local result = {}
  for _, e in ipairs(trace.entries) do
    if e.kind == kind then result[#result+1] = e end
  end
  return result
end

-- Peripheral-Call-Sequenz für ein Gerät extrahieren
function M.peripheral_calls(trace, device_name, method)
  local result = {}
  for _, e in ipairs(trace.entries) do
    if e.kind == "peripheral_call" and
       e.data.name == device_name and
       (not method or e.data.method == method) then
      result[#result+1] = e
    end
  end
  return result
end

-- Entscheidungen extrahieren
function M.decisions(trace, kind)
  local result = {}
  for _, e in ipairs(trace.entries) do
    if e.kind == "decision" and (not kind or e.data.kind == kind) then
      result[#result+1] = e
    end
  end
  return result
end

return M
