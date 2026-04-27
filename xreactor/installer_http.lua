local M = {}

function M.download_url(http_api, url, retries, retry_delay_seconds, warn)
  if not http_api or type(http_api.get) ~= "function" then
    return nil, "HTTP API unavailable"
  end
  if type(url) ~= "string" or url == "" then
    return nil, "invalid url"
  end
  local last_error = nil
  for attempt = 1, retries do
    local ok, response = pcall(http_api.get, url)
    if ok and response then
      if response.getResponseCode then
        local code = response.getResponseCode()
        if code ~= 200 then
          pcall(response.close)
          last_error = "HTTP " .. tostring(code) .. " for " .. url
        else
          local ok_read, body = pcall(response.readAll)
          pcall(response.close)
          if ok_read and type(body) == "string" then
            return body
          end
          last_error = "Failed to read response from " .. url
        end
      else
        local ok_read, body = pcall(response.readAll)
        pcall(response.close)
        if ok_read and type(body) == "string" then
          return body
        end
        last_error = "Failed to read response from " .. url
      end
    else
      last_error = "Failed to download " .. url
    end
    if attempt < retries then
      if warn then warn(string.format("Download attempt %d/%d failed for %s (%s)", attempt, retries, tostring(url), tostring(last_error))) end
      if os and type(os.sleep) == "function" then os.sleep(retry_delay_seconds) end
    end
  end
  return nil, tostring(last_error or ("Failed to download " .. url))
end

function M.is_html_content(content)
  if type(content) ~= "string" then return false end
  local snippet = content:sub(1, 200):lower()
  return snippet:find("<html", 1, true) or snippet:find("<!doctype", 1, true)
end

return M
