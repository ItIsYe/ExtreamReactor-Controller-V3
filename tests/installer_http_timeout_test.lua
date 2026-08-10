local repo_root = os.getenv("REPO_ROOT") or "."
local module_path = repo_root .. "/xreactor/installer/http.lua"

local function load_module()
  local chunk, err = loadfile(module_path)
  if not chunk then error("failed loading installer/http.lua: " .. tostring(err)) end
  return chunk()
end

local original_http = _G.http
local original_start_timer = os.startTimer
local original_pull_event = os.pullEvent
local original_sleep = os.sleep
local original_epoch = os.epoch

local requested_url
local cancelled_url
_G.http = {
  request = function(url)
    requested_url = url
    return true
  end,
  cancel = function(url)
    cancelled_url = url
  end,
}
os.startTimer = function(timeout)
  if timeout ~= 7 then error("expected configured 7s timeout, got " .. tostring(timeout)) end
  return 91
end
os.pullEvent = function()
  return "timer", 91
end
os.sleep = function() end
os.epoch = function() return 1234 end

local http_mod = load_module()
local body, err = http_mod.download("https://example.invalid/file", {
  retries = 1,
  timeout_s = 7,
})
if body ~= nil or not tostring(err):find("timeout after 7s", 1, true) then
  error("stalled request must fail with a bounded timeout, got body=" .. tostring(body) .. " err=" .. tostring(err))
end
if type(requested_url) ~= "string" or cancelled_url ~= requested_url then
  error("timed-out request must be cancelled using the exact requested URL")
end

-- Legacy/synchronous fallback and API-free Atom parsing.
local fake_sha = "0123456789abcdef0123456789abcdef01234567"
_G.http = {
  get = function(_url)
    return {
      getResponseCode = function() return 200 end,
      readAll = function()
        return '<entry><id>tag:github.com,2008:Grit::Commit/' .. fake_sha .. '</id></entry>'
      end,
      close = function() end,
    }
  end,
}
os.startTimer = nil
os.pullEvent = nil
http_mod = load_module()
local resolved = http_mod.resolve_sha()
if resolved ~= fake_sha then
  error("commit feed SHA resolution failed: " .. tostring(resolved))
end

_G.http = original_http
os.startTimer = original_start_timer
os.pullEvent = original_pull_event
os.sleep = original_sleep
os.epoch = original_epoch

print("installer_http_timeout_test.lua: ok")
