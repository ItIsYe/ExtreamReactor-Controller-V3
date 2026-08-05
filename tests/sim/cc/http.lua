-- tests/sim/cc/http.lua  Phase 4.5
-- HTTP-Eventmodell: http.request() → http_success / http_failure Events
-- Responses werden vorab konfiguriert (Stub-Tabelle).

local http_mod = {}

function http_mod.new(event_queue)
  local stubs = {}   -- url → { body, status, headers } | { error }
  local pending = {} -- url → true (Anfrage in Flight)

  local http = {}

  -- Stub registrieren
  function http.stub(url, response)
    stubs[url] = response
  end

  -- http.request(url) → feuert Event beim nächsten tick()
  function http.request(url, body, headers)
    pending[url] = true
    return true
  end

  -- http.get(url) → synchron, gibt Response-Handle zurück
  function http.get(url)
    local stub = stubs[url]
    if not stub or stub.error then return false end
    local content = stub.body or ""
    return {
      readAll  = function() return content end,
      readLine = function() return nil end,
      getResponseCode = function() return stub.status or 200 end,
      getResponseHeaders = function() return stub.headers or {} end,
      close = function() end,
    }
  end

  -- tick(): ausstehende Requests in Events umwandeln
  function http.tick()
    for url in pairs(pending) do
      local stub = stubs[url]
      if stub then
        if stub.error then
          event_queue:push("http_failure", url, stub.error)
        else
          local body = stub.body or ""
          local handle = {
            readAll  = function() return body end,
            readLine = function() return nil end,
            getResponseCode = function() return stub.status or 200 end,
            getResponseHeaders = function() return stub.headers or {} end,
            close = function() end,
          }
          event_queue:push("http_success", url, handle)
        end
      else
        event_queue:push("http_failure", url, "no stub for " .. url)
      end
      pending[url] = nil
    end
  end

  return http
end

return http_mod
