-- tests/sim_http_contract_test.lua
local eq_cls  = dofile("tests/sim/cc/event_queue.lua")
local http_mod= dofile("tests/sim/cc/http.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

local q    = eq_cls.new()
local http = http_mod.new(q)

-- Stub + request → http_success event
http.stub("https://example.com/ok", { body = "response body", status = 200 })
http.request("https://example.com/ok")
http.tick()

A(q:size(), 1, "one event")
local ev, url, handle = q:pull("http_success")
A(ev, "http_success", "event name")
A(url, "https://example.com/ok", "url")
T(handle ~= nil, "handle not nil")
A(handle.readAll(), "response body", "body")

-- Fehler-Stub → http_failure
http.stub("https://fail.example.com", { error = "connection refused" })
http.request("https://fail.example.com")
http.tick()
local ef, uf, emsg = q:pull()
A(ef, "http_failure", "failure event")
A(uf, "https://fail.example.com", "fail url")
T(tostring(emsg):find("connection") ~= nil, "error msg")

-- http.get (synchron)
local h = http.get("https://example.com/ok")
T(h ~= nil, "get handle")
A(h.readAll(), "response body", "get body")

-- Kein Stub → failure
http.request("https://unknown.url")
http.tick()
local ef2, uf2 = q:pull()
A(ef2, "http_failure", "no stub failure")
T(tostring(uf2):find("unknown") ~= nil, "unknown url")

print("sim_http_contract_test.lua: ok")
