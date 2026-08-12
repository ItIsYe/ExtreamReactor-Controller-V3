-- tests/sim/invariants/update.lua  Phase 7.2
-- Update-Invarianten: Manifest-Hash, Versions-Monotonie.

local M = {}

-- Manifest-Version steigt nie ab
function M.version_monotone()
  local last_ver = -1
  return function(world, tick)
    local ver = world.manifest_version
    if ver then
      if ver < last_ver then
        return false, string.format("tick=%d manifest version %d < previous %d", tick, ver, last_ver)
      end
      last_ver = ver
    end
    return true
  end
end

-- Installer bleibt hash-konsistent
function M.installer_hash_stable(expected_hash)
  return function(world, tick)
    local h = world.installer_hash
    if h and h ~= expected_hash then
      return false, string.format("tick=%d installer hash changed: %s != %s", tick, h, expected_hash)
    end
    return true
  end
end

return M
