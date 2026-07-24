package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer core/utils.lua's write_config(): file.write()/
-- file.close() konnten werfen (z.B. Datentraeger voll/schreibgeschuetzt),
-- ungeschuetzt widersprach das dem eigenen Funktionskommentar ("Do NOT
-- call error() here ... Log and return a boolean so callers can decide").
-- Ein Fehlschlag hier crashte den aufrufenden Node trotzdem hart -- z.B.
-- VALVE beim automatischen trusted_source-Pairing (nodes/valve/main.lua),
-- das write_config() direkt (ohne eigenes pcall) aufruft und dadurch bei
-- JEDEM eingehenden SET_VALVE-Kommando erneut abstuerzte, sobald der
-- Schreibvorgang aus Umgebungsgruenden fehlschlug.

local files = {}

_G.textutils = {
  serialize = function(value)
    if type(value) ~= "table" then return tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
      out[#out + 1] = tostring(k) .. "=" .. tostring(value[k])
    end
    return "{" .. table.concat(out, ";") .. "}"
  end,
  unserialize = function() return nil end,
}

_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function(p)
    local dir = p:match("^(.*)/[^/]+$")
    return dir or ""
  end,
  makeDir = function() end,
  open = function(p, mode)
    if mode == "w" then
      return {
        write = function() error("simulated disk-full write failure", 0) end,
        close = function() files[p] = "" end,
      }
    end
    return nil
  end,
}

local utils = require('core.utils')

local ok_call, ok_result, err_result = pcall(utils.write_config, "/xreactor/config/valve.lua", { trusted_source = "FUEL-1" })
if not ok_call then
  error("write_config must never throw even when the underlying file.write() throws: " .. tostring(ok_result))
end
if ok_result ~= false then
  error("write_config must report failure (ok=false) when file.write() throws, got ok=" .. tostring(ok_result))
end
if not tostring(err_result):find("write_failed", 1, true) then
  error("expected a write_failed error code, got: " .. tostring(err_result))
end

print("utils_write_config_write_failure_test.lua: ok")
