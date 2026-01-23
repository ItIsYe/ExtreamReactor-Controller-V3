local build_info = {
  version = "main",
  commit = nil,
  installer_core_version = nil
}

local function load_release()
  if not fs or not fs.exists then
    return nil
  end
  if not fs.exists("/xreactor/installer/release.lua") then
    return nil
  end
  local ok, data = pcall(dofile, "/xreactor/installer/release.lua")
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data
end

function build_info.get()
  local release = load_release()
  if release then
    build_info.version = release.commit_sha or build_info.version
    build_info.commit = release.commit_sha or build_info.commit
    build_info.installer_core_version = release.installer_core_version or build_info.installer_core_version
  end
  return {
    version = build_info.version,
    commit = build_info.commit,
    installer_core_version = build_info.installer_core_version
  }
end

return build_info
