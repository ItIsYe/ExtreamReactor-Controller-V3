local BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/main"
local RELEASE_PATH = "xreactor/installer/release.lua"
local INSTALLER_PATH = "/xreactor/installer/installer.lua"

local function download(url)
  local response = http.get(url)
  if not response then
    return nil
  end
  local content = response.readAll()
  response.close()
  return content
end

local function load_release()
  local content = download(BASE_URL .. "/" .. RELEASE_PATH)
  if not content then
    print("Installer download failed.")
    return nil
  end
  local loader = load(content, "release", "t", {})
  if not loader then
    print("Installer download corrupted.")
    return nil
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then
    print("Installer download corrupted.")
    return nil
  end
  if type(data.commit_sha) ~= "string" then
    print("Installer download corrupted.")
    return nil
  end
  return data
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

local function fetch_installer(release)
  local url = ("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/%s/xreactor/installer/installer.lua"):format(release.commit_sha)
  local content = download(url)
  if not content then
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
  local loader, err = loadfile(INSTALLER_PATH)
  if not loader then
    print("Installer missing or corrupted.")
    return
  end
  return loader()
end

if not http then
  error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
end

local release = load_release()
if not release then
  return
end

if not fs.exists(INSTALLER_PATH) then
  if not fetch_installer(release) then
    if not fetch_installer(release) then
      print("Installer download corrupted.")
      return
    end
  end
end

local loader = loadfile(INSTALLER_PATH)
if not loader then
  if not fetch_installer(release) then
    print("Installer download corrupted.")
    return
  end
end

run_installer()
