local build_info = {
  version = "main",
  commit = nil,
  release_id = nil,
  manifest_id = nil,
  manifest_version = nil,
  installer_core_version = nil
}

local function load_release()
  if not fs or not fs.exists then
    return nil
  end
  if not fs.exists("/xreactor/release.lua") then
    return nil
  end
  local ok, data = pcall(dofile, "/xreactor/release.lua")
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
    build_info.release_id = release.release_id or build_info.release_id
    build_info.manifest_id = release.manifest_id or build_info.manifest_id
    build_info.manifest_version = release.manifest_version or build_info.manifest_version
    build_info.installer_core_version = release.installer_core_version or build_info.installer_core_version
  end
  return {
    version = build_info.version,
    commit = build_info.commit,
    release_id = build_info.release_id,
    manifest_id = build_info.manifest_id,
    manifest_version = build_info.manifest_version,
    installer_core_version = build_info.installer_core_version
  }
end

return build_info
