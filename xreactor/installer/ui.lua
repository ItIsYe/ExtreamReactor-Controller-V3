-- installer/ui.lua
-- Terminal-Ausgabe für den Installer.

local M = {}
local function p(msg) pcall(print, tostring(msg)) end
local function w(msg) pcall(write, tostring(msg)) end

function M.header(title) p(""); p("=== " .. tostring(title) .. " ==="); p("") end
function M.info(msg)  p("[INFO] " .. tostring(msg)) end
function M.warn(msg)  p("[WARN] " .. tostring(msg)) end
function M.error(msg) p("[ERR ] " .. tostring(msg)) end
function M.ok(msg)    p("[ OK ] " .. tostring(msg)) end

function M.progress(done, total, label)
  local pct = total > 0 and math.floor(done / total * 100) or 0
  p(string.format("  [%3d%%] %d/%d %s", pct, done, total, tostring(label or "")))
end

local ROLES = {
  { key = "master",       label = "MASTER"       },
  { key = "rt",           label = "RT"           },
  { key = "energy",       label = "ENERGY"       },
  { key = "water",        label = "WATER"        },
  { key = "fuel",         label = "FUEL"         },
  { key = "reprocessing", label = "REPROCESSING" },
  { key = "log",          label = "LOG"          },
}

function M.select_role()
  p("")
  for i, r in ipairs(ROLES) do p(string.format("  %d) %s", i, r.label)) end
  p("")
  w("Rolle wählen [1-" .. #ROLES .. "]: ")
  local choice = tonumber(read() or "")
  if choice and ROLES[choice] then return ROLES[choice] end
  return nil
end

function M.confirm(question)
  if _G.__xreactor_remote_update then p(question .. " [j/n]: j (automatisch)"); return true end
  while true do
    w(question .. " [j/n]: ")
    local a = (read() or ""):lower()
    if a == "j" or a == "ja" or a == "y" or a == "yes" then return true end
    if a == "n" or a == "nein" or a == "no" then return false end
    p("Bitte j oder n eingeben.")
  end
end

return M
