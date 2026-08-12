-- tests/sim/cc/fs.lua  Phase 4.5
-- In-Memory VFS: Dateien als Strings, Verzeichnisse implizit.

local fs_mod = {}

function fs_mod.new(initial_files)
  -- Dateien: Pfad → Inhalt (string)
  local files = {}
  if initial_files then
    for k, v in pairs(initial_files) do files[k] = v end
  end

  local fs = {}

  local function norm(p)
    -- Kanonischer Pfad: führenden / entfernen, // → /
    p = p:gsub("//+", "/")
    if p:sub(1,1) == "/" then p = p:sub(2) end
    return p
  end

  local function parent(p)
    local dir = p:match("^(.*)/[^/]+$") or ""
    return dir
  end

  function fs.exists(path) return files[norm(path)] ~= nil end
  function fs.isDir(path)
    local n = norm(path)
    for k in pairs(files) do
      if k:sub(1, #n+1) == n .. "/" then return true end
    end
    return false
  end
  function fs.isReadOnly() return false end
  function fs.getSize(path)
    local c = files[norm(path)]
    return c and #c or 0
  end

  function fs.list(path)
    local n = norm(path)
    local prefix = n == "" and "" or n .. "/"
    local seen = {}
    local result = {}
    for k in pairs(files) do
      if k:sub(1, #prefix) == prefix then
        local rest = k:sub(#prefix+1)
        local name = rest:match("^([^/]+)") or rest
        if name and name ~= "" and not seen[name] then
          seen[name] = true
          result[#result+1] = name
        end
      end
    end
    table.sort(result)
    return result
  end

  function fs.makeDir(path)
    -- Kein expliziter Eintrag nötig (implizit durch Dateien)
    local n = norm(path)
    if n ~= "" then
      -- Marker-Datei für leere Verzeichnisse
      files[n .. "/__dir__"] = ""
    end
  end

  function fs.delete(path)
    local n = norm(path)
    files[n] = nil
    -- Rekursiv löschen
    local prefix = n .. "/"
    for k in pairs(files) do
      if k:sub(1, #prefix) == prefix then files[k] = nil end
    end
  end

  function fs.move(from, to)
    local fn, tn = norm(from), norm(to)
    files[tn] = files[fn]
    files[fn] = nil
  end

  function fs.copy(from, to)
    files[norm(to)] = files[norm(from)]
  end

  function fs.combine(a, b)
    if b:sub(1,1) == "/" then return b end
    if a == "" then return b end
    return a:gsub("/$","") .. "/" .. b
  end

  function fs.getName(path) return path:match("([^/]+)$") or path end
  function fs.getDir(path)  return path:match("^(.*)/[^/]+$") or "" end

  function fs.open(path, mode)
    local n = norm(path)
    if mode == "r" then
      local content = files[n]
      if content == nil then return nil end
      local pos = 1
      return {
        readAll  = function() return content end,
        readLine = function()
          if pos > #content then return nil end
          local nl = content:find("\n", pos, true)
          if nl then
            local line = content:sub(pos, nl-1)
            pos = nl + 1
            return line
          else
            local line = content:sub(pos)
            pos = #content + 1
            return line
          end
        end,
        read  = function() if pos > #content then return nil end; local c=content:sub(pos,pos); pos=pos+1; return c end,
        close = function() end,
      }
    elseif mode == "w" then
      local buf = {}
      return {
        write     = function(s) buf[#buf+1] = tostring(s) end,
        writeLine = function(s) buf[#buf+1] = tostring(s) .. "\n" end,
        flush     = function() end,
        close     = function() files[n] = table.concat(buf) end,
      }
    elseif mode == "a" then
      local existing = files[n] or ""
      local buf = {existing}
      return {
        write     = function(s) buf[#buf+1] = tostring(s) end,
        writeLine = function(s) buf[#buf+1] = tostring(s) .. "\n" end,
        flush     = function() end,
        close     = function() files[n] = table.concat(buf) end,
      }
    end
    return nil
  end

  -- Interner Zugriff für Tests
  function fs._files() return files end
  function fs._set(path, content) files[norm(path)] = content end

  return fs
end

return fs_mod
