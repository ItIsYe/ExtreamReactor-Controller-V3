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

-- Ergebnis der letzten Dateipruefung dieses Rechners, kurz gefasst.
--
-- installer/auto_update.lua legt das volle Ergebnis von
-- core/install_integrity.lua's check() als _G.__xreactor_install_integrity
-- ab (start.lua laedt Rolle und Auto-Updater mit demselben _G). Die
-- Zusammenfassung geht mit jedem STATUS-Paket an MASTER
-- (services/telemetry_service.lua: payload.meta.build) und erscheint dort
-- auf der Seite "Updates". Der HEARTBEAT nimmt aus build_info nur
-- manifest_version mit (comms_service:send_heartbeat) -- er bleibt, wie er
-- ist.
--
--   ok       true: alle Dateien passen; false: Abweichung; nil: keine
--            Pruefsummenliste (Installation vor v814)
--   bad      Zahl fehlender + veraenderter Dateien
--   version  die Fassung, gegen die geprueft wurde -- MASTER zeigt das
--            Ergebnis nur, wenn sie zur gemeldeten Fassung passt
--
-- Vor der ersten Pruefung nach dem Start (beim ersten Update-Check) gibt es
-- kein Ergebnis: nil.
local function integrity_summary()
  local result = type(_G) == "table" and rawget(_G, "__xreactor_install_integrity") or nil
  if type(result) ~= "table" then return nil end
  local missing = type(result.missing) == "table" and #result.missing or 0
  local changed = type(result.changed) == "table" and #result.changed or 0
  return {
    ok = result.ok,
    checked = tonumber(result.checked),
    bad = missing + changed,
    digest = result.payload_digest,
    version = tonumber(result.manifest_version),
  }
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
    installer_core_version = build_info.installer_core_version,
    integrity = integrity_summary()
  }
end

build_info.integrity_summary = integrity_summary

return build_info
