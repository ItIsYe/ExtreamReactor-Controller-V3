-- tests/manifest_speaker_alarm_role_scope_test.lua
--
-- MANIFEST-P1 (docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md,
-- Abschnitt 17): optional/speaker_alarm.lua hatte in xreactor/manifest.lua
-- kein required_for -- installer/manifest.lua's files_for_role() fuegt
-- einen roles.*-Eintrag aber nur hinzu, wenn "always=true" ODER
-- "required_for" die gewaehlte Rolle enthaelt. Ohne required_for wurde
-- die Datei fuer KEINE Rolle installiert, selbst wenn der Nutzer das
-- Feature interaktiv ausgewaehlt hatte -- und installer/init.lua's
-- matches_role() interpretierte ein fehlendes required_for zusaetzlich
-- als "Feature passt zu jeder Rolle", bot es also faelschlich ueberall an.

local function load_table(path)
  local chunk, err = loadfile(path)
  if not chunk then error("failed loading " .. tostring(path) .. ": " .. tostring(err)) end
  local ok, result = pcall(chunk)
  if not ok then error("failed executing " .. tostring(path) .. ": " .. tostring(result)) end
  return result
end

local manifest = load_table("xreactor/manifest.lua")
local manifest_mod = dofile("xreactor/installer/manifest.lua")

-- Every role that actually does require("optional.speaker_alarm") --
-- directly (nodes/*/main.lua, nodes/rt/monitor_ui.lua) or indirectly via
-- services/alert_service.lua (enabled by default, opt-out only) which
-- every one of these roles instantiates.
local ROLES_NEEDING_IT = { "RT", "ENERGY", "WATER", "FUEL", "REPROCESSING", "LOG", "MASTER" }

for _, role_label in ipairs(ROLES_NEEDING_IT) do
  local expected = manifest_mod.files_for_role(manifest, role_label, { speaker_alarm = true })
  assert(expected["optional/speaker_alarm.lua"] ~= nil,
    "optional/speaker_alarm.lua must be installable for role " .. role_label .. " once the feature is selected")
end

-- VALVE never requires optional.speaker_alarm or services/alert_service --
-- selecting the feature there must not pull the file in.
do
  local expected = manifest_mod.files_for_role(manifest, "VALVE", { speaker_alarm = true })
  assert(expected["optional/speaker_alarm.lua"] == nil,
    "optional/speaker_alarm.lua must not be offered/installed for VALVE (never required there)")
end

-- The feature stays opt-in: not selecting it must not install the file,
-- even for a role that would otherwise qualify.
do
  local expected = manifest_mod.files_for_role(manifest, "RT", {})
  assert(expected["optional/speaker_alarm.lua"] == nil,
    "optional/speaker_alarm.lua must stay opt-in -- unselected feature must not be installed")
end

print("manifest_speaker_alarm_role_scope_test.lua: ok")
