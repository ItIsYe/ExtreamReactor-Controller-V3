local BASE_URL_MAIN = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/main"
local INSTALLER_PATH = "/xreactor/installer/installer.lua"
local INSTALLER_MIN_BYTES = 200
local INSTALLER_SANITY_MARKER = "local function main"

local function is_html_payload(content)
  if not content then return false end
  local head = content:sub(1, 200)
  if head:match("^%s*<!DOCTYPE") then return true end
  if head:match("^%s*<html") then return true end
  if head:find("<body") then return true end
  return false
end

local function download_url_checked(url)
  local response = http.get(url)
  if not response then
    return nil, { url = url, code = nil, reason = "timeout", html = false }
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local content = response.readAll()
  response.close()
  if not content or content == "" then
    return nil, { url = url, code = code, reason = "empty", html = false }
  end
  local html = is_html_payload(content)
  if html then
    return nil, { url = url, code = code, reason = "html", html = true }
  end
  if code and code ~= 200 then
    return nil, { url = url, code = code, reason = "status", html = html }
  end
  return content, { url = url, code = code, reason = nil, html = html }
end

local function download_with_retries(urls, attempts, backoff_seconds)
  local last_meta = nil
  for attempt = 1, attempts do
    for _, url in ipairs(urls) do
      local content, meta = download_url_checked(url)
      if content then
        return content, meta
      end
      last_meta = meta
      print(("Download failed: %s (code=%s reason=%s)"):format(
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason)
      ))
    end
    if attempt < attempts then
      os.sleep(backoff_seconds * attempt)
    end
  end
  return nil, last_meta
end

local function validate_installer_content(content)
  if not content or #content < INSTALLER_MIN_BYTES then
    return false, "content too short"
  end
  if not content:find(INSTALLER_SANITY_MARKER, 1, true) then
    return false, "sanity check failed"
  end
  local loader, err = load(content, "installer", "t", {})
  if not loader then
    return false, err or "syntax error"
  end
  return true
end

local function write_file(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local file = fs.open(path, "w")
  if not file then
    return false
  end
  file.write(content)
  file.close()
  return true
end

local function fetch_installer()
  local urls = {
    string.format("%s/xreactor/installer/installer.lua", BASE_URL_MAIN)
  }
  local content = select(1, download_with_retries(urls, 3, 1))
  if not content then
    return false
  end
  local valid = validate_installer_content(content)
  if not valid then
    return false
  end
  if not write_file(INSTALLER_PATH, content) then
    return false
  end
  local loader = loadfile(INSTALLER_PATH)
  if not loader then
    fs.delete(INSTALLER_PATH)
    return false
  end
  return true
end

local function run_installer()
  local loader = loadfile(INSTALLER_PATH)
  if not loader then
    print("Installer missing or corrupted.")
    return
  end
  return loader()
end

if not http then
  error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
end

if not fs.exists(INSTALLER_PATH) then
  if not fetch_installer() then
    if not fetch_installer() then
      print("Installer download corrupted.")
      return
    end
  end
end

local loader = loadfile(INSTALLER_PATH)
if not loader then
  if not fetch_installer() then
    print("Installer download corrupted.")
    return
  end
end

run_installer()
