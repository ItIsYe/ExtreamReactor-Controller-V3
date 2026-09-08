-- installer/http.lua akzeptierte bisher ausschliesslich Response-Code 200,
-- waehrend installer/auto_update.lua (das gegen denselben GitHub-Raw-Server
-- laeuft) den gesamten 2xx-Bereich (200-299) als Erfolg wertet. Ein 2xx-Code
-- ausserhalb von genau 200 liesse http.lua den Download unnoetig als
-- fehlgeschlagen melden, obwohl derselbe Server-Response in auto_update.lua
-- als Erfolg durchgegangen waere. http.lua muss denselben Bereich nutzen.

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local function make_response(code, body)
  return {
    getResponseCode = function() return code end,
    readAll = function() return body end,
    close = function() end,
  }
end

-- Fall 1: Code 204 (No Content, aber im 2xx-Bereich) muss als Erfolg gelten.
_G.http = { get = function() return make_response(204, "return {ok=true}") end }
package.loaded["installer.http"] = nil
local http_mod = require("installer.http")
local body, err = http_mod.download("https://example.com/beta/xreactor/manifest.lua", { retries = 1 })
if body ~= "return {ok=true}" then
  error("expected HTTP 204 to be treated as success (2xx range), got body=" .. tostring(body) .. " err=" .. tostring(err))
end

-- Fall 2: Code 404 muss weiterhin als Fehler gelten.
_G.http = { get = function() return make_response(404, "not found") end }
package.loaded["installer.http"] = nil
http_mod = require("installer.http")
body, err = http_mod.download("https://example.com/beta/xreactor/manifest.lua", { retries = 1 })
if body ~= nil then
  error("expected HTTP 404 to still fail, got body")
end
if not tostring(err):find("404", 1, true) then
  error("expected the HTTP 404 error to be reported, got: " .. tostring(err))
end

-- Fall 3: Code 301 (ausserhalb 2xx) muss weiterhin als Fehler gelten --
-- dies ist keine pauschale Lockerung, sondern exakt der 2xx-Bereich.
_G.http = { get = function() return make_response(301, "moved") end }
package.loaded["installer.http"] = nil
http_mod = require("installer.http")
body, err = http_mod.download("https://example.com/beta/xreactor/manifest.lua", { retries = 1 })
if body ~= nil then
  error("expected HTTP 301 to still fail (outside 2xx), got body")
end

print("installer_http_success_code_range_test.lua: ok")
