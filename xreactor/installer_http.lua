local M = {}

-- Default timeout for a single HTTP request attempt (seconds).
-- If the server does not respond within this time, the attempt is aborted.
local DEFAULT_TIMEOUT_SECONDS = 15

-- Download a URL with retry logic and a per-attempt client-side timeout.
--
-- Uses http.request() (async) instead of http.get() (no timeout) so the
-- installer does not hang indefinitely when GitHub is slow or the connection
-- stalls. Each attempt fires http.request, then waits for http_success or
-- http_failure events (or a timer event for timeout).
--
-- http_api:       CC http API object (must have .get and .request)
-- url:            URL string
-- retries:        number of attempts (default 3)
-- retry_delay:    seconds between retries (default 2)
-- warn:           optional function(msg) for warnings
-- timeout:        per-attempt timeout in seconds (default 15)
function M.download_url(http_api, url, retries, retry_delay_seconds, warn, timeout)
  if not http_api then
    return nil, "HTTP API unavailable"
  end
  if type(url) ~= "string" or url == "" then
    return nil, "invalid url"
  end

  retries           = tonumber(retries) or 3
  retry_delay_seconds = tonumber(retry_delay_seconds) or 2
  timeout           = tonumber(timeout) or DEFAULT_TIMEOUT_SECONDS

  -- Prefer async http.request for timeout support;
  -- fall back to http.get if request is unavailable (very old CC versions).
  local use_async = type(http_api.request) == "function"
                 and type(os) == "table"
                 and type(os.startTimer) == "function"
                 and type(os.pullEvent) == "function"

  local function attempt_async(u)
    -- Fire async request
    local ok_req = pcall(http_api.request, u)
    if not ok_req then
      return nil, "http.request() failed to start"
    end

    local timer = os.startTimer(timeout)
    while true do
      local event, p1, p2, p3 = os.pullEvent()

      if event == "http_success" and p1 == u then
        -- p2 = response handle
        local response = p2
        if response and type(response.getResponseCode) == "function" then
          local code = response.getResponseCode()
          if code ~= 200 then
            pcall(response.close)
            return nil, "HTTP " .. tostring(code)
          end
        end
        if response then
          local ok_read, body = pcall(response.readAll)
          pcall(response.close)
          if ok_read and type(body) == "string" then
            return body
          end
          return nil, "failed to read response"
        end
        return nil, "empty response"

      elseif event == "http_failure" and p1 == u then
        -- p2 = error string, p3 = response handle (if any)
        if p3 then pcall(p3.close) end
        return nil, tostring(p2 or "http_failure")

      elseif event == "timer" and p1 == timer then
        -- Timeout: try to cancel the request
        if type(http_api.cancelRequest) == "function" then
          pcall(http_api.cancelRequest, u)
        end
        return nil, string.format("timeout after %ds", timeout)
      end
      -- Ignore unrelated events (modem_message, etc.) and keep waiting.
    end
  end

  local function attempt_sync(u)
    local ok, response = pcall(http_api.get, u)
    if not ok or not response then
      return nil, "http.get failed"
    end
    if type(response.getResponseCode) == "function" then
      local code = response.getResponseCode()
      if code ~= 200 then
        pcall(response.close)
        return nil, "HTTP " .. tostring(code)
      end
    end
    local ok_read, body = pcall(response.readAll)
    pcall(response.close)
    if ok_read and type(body) == "string" then return body end
    return nil, "failed to read response"
  end

  local last_error
  for attempt = 1, retries do
    local body, err

    if use_async then
      body, err = attempt_async(url)
    else
      body, err = attempt_sync(url)
    end

    if body then return body end

    last_error = err
    if attempt < retries then
      if warn then
        warn(string.format(
          "Download attempt %d/%d failed for %s (%s)%s",
          attempt, retries, url, tostring(last_error),
          use_async and "" or " [sync fallback - no timeout]"
        ))
      end
      if os and type(os.sleep) == "function" and retry_delay_seconds > 0 then
        os.sleep(retry_delay_seconds)
      end
    end
  end

  return nil, tostring(last_error or ("failed to download " .. url))
end

function M.is_html_content(content)
  if type(content) ~= "string" then return false end
  local snippet = content:sub(1, 200):lower()
  return snippet:find("<html", 1, true) or snippet:find("<!doctype", 1, true)
end

return M
