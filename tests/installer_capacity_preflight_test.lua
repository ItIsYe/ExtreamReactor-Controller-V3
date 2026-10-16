-- tests/installer_capacity_preflight_test.lua
--
-- Gemeldet aus dem Spiel (Bild): eine RT-Installation lief bis
--     [100%] 82/82 manifest.lua
-- und brach dort ab mit
--     Installation: not enough space for /xreactor/manifest.lua
--     (free=13241 needed=23733)
--
-- Zwei Dinge daran waren falsch, und beide sind hier abgesichert:
--
--  1. Der Abbruch kam ZU SPAET. installer/init.lua loescht die alte
--     Installation, bevor es die neue schreibt -- der Rechner blieb also
--     mit einem halben Baum liegen und lief gar nicht mehr. Ob der
--     Speicher reicht, muss VORHER feststehen.
--  2. Die Meldung las sich wie ein Problem mit dieser einen Datei,
--     obwohl in Wahrheit der Rechner fuer die Rolle zu klein ist. Sie
--     muss sagen, was zu tun ist.

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local function assert_true(v, m) if not v then error(m or "assert_true failed", 2) end end

-- Ein Dateisystem mit fester Quote, in dem ein alter /xreactor-Baum liegt.
local function make_fs(quota, old_tree_bytes)
  local files, dirs = {}, { ["/"] = true, ["/xreactor"] = true }
  if old_tree_bytes > 0 then
    files["/xreactor/alt.lua"] = string.rep("a", old_tree_bytes)
  end
  local function used()
    local total = 0
    for _, c in pairs(files) do total = total + #c end
    return total
  end
  return {
    getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
    exists = function(p) return files[p] ~= nil or dirs[p] == true end,
    isDir = function(p) return dirs[p] == true end,
    makeDir = function(p) dirs[p] = true end,
    getFreeSpace = function() return quota - used() end,
    getSize = function(p) return files[p] and #files[p] or 0 end,
    list = function(p)
      local names, prefix = {}, p .. "/"
      for path in pairs(files) do
        if path:sub(1, #prefix) == prefix then names[#names + 1] = path:sub(#prefix + 1) end
      end
      return names
    end,
    delete = function(p) files[p] = nil; dirs[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    open = function() return nil end,
  }
end

package.loaded["installer.stage"] = nil
local stage = require("installer.stage")

-- ── 1. Der Platz des alten Baums zaehlt mit ──────────────────────────────
--
-- Er wird vor der Installation geloescht. Ohne diese Anrechnung wuerde
-- jede Aktualisierung eines fast vollen Rechners abgelehnt, auch wenn die
-- neue Fassung genauso gross ist wie die alte.

do
  _G.fs = make_fs(1000000, 700000)   -- 700k belegt, 300k frei
  local ok = stage.check_capacity(700000, "/xreactor")
  assert_true(ok, "eine gleich grosse Neuinstallation muss passen -- der alte Baum wird ja frei")
end

-- ── 2. Zu klein wird VORHER erkannt, mit brauchbarer Meldung ─────────────

do
  _G.fs = make_fs(1000000, 700000)
  local ok, err = stage.check_capacity(990000, "/xreactor")
  assert_true(not ok, "was nicht passt, muss abgelehnt werden")
  local msg = tostring(err)
  assert_true(msg:find("reicht fuer diese Rolle nicht", 1, true) ~= nil,
    "die Meldung muss sagen, dass der RECHNER zu klein ist, nicht eine Datei: " .. msg)
  assert_true(msg:find("computer_space_limit", 1, true) ~= nil,
    "und wo man das aendert: " .. msg)
  assert_true(msg:find("alte Installation bleibt unangetastet", 1, true) ~= nil,
    "und dass nichts kaputtgegangen ist: " .. msg)
end

-- ── 3. Kopfraum ist eingerechnet ─────────────────────────────────────────
--
-- Ein Vorab-Check, der auf das letzte Byte genau passt, ist nichts wert:
-- Journal, Rolle, Konfiguration und der Verschnitt je Datei kommen noch
-- dazu. Genau auf Kante darf deshalb NICHT durchgehen.

do
  _G.fs = make_fs(100000, 0)
  assert_true(not stage.check_capacity(100000, "/xreactor"),
    "eine Installation, die den Speicher exakt ausfuellt, darf nicht durchgehen")
  assert_true(stage.check_capacity(100000 - stage.SPACE_HEADROOM_BYTES, "/xreactor"),
    "mit Kopfraum darunter aber schon")
end

-- ── 4. Ohne bekanntes Limit wird nicht blockiert ─────────────────────────
--
-- Ein Emulator oder eine Diskette ohne Quote meldet kein sinnvolles
-- getFreeSpace. Dann darf der Check nicht die Installation verhindern.

do
  _G.fs = make_fs(1000, 0)
  _G.fs.getFreeSpace = function() return "unlimited" end
  assert_true(stage.check_capacity(999999999, "/xreactor"),
    "ohne bekanntes Speicherlimit darf der Check nichts verhindern")
  _G.fs.getFreeSpace = nil
  assert_true(stage.check_capacity(999999999, "/xreactor"),
    "und ohne getFreeSpace erst recht nicht")
end

-- ── 5. Der Aufruf steht wirklich vor dem Loeschen ────────────────────────
--
-- Der ganze Punkt ist die REIHENFOLGE. Steht der Check hinter dem
-- fs.delete(INSTALL_ROOT), ist er wertlos -- dann ist die alte
-- Installation schon weg, wenn er anschlaegt.

do
  local f = assert(io.open("xreactor/installer/init.lua", "r"))
  local src = f:read("*a")
  f:close()

  local check_pos = src:find("stage_mod.check_capacity", 1, true)
  local delete_pos = src:find("pcall(fs.delete, INSTALL_ROOT)", 1, true)
  local plan_pos = src:find("plan_validator_mod.validate", 1, true)
  assert_true(check_pos ~= nil, "installer/init.lua muss den Speicher ueberhaupt pruefen")
  assert_true(delete_pos ~= nil, "und die alte Installation loeschen -- sonst stimmt dieser Test nicht mehr")
  assert_true(check_pos < delete_pos,
    "die Speicherpruefung MUSS vor dem Loeschen der alten Installation stehen,"
      .. " sonst bleibt der Rechner bei zu wenig Platz halb installiert liegen")
  assert_true(plan_pos ~= nil and plan_pos < check_pos,
    "und nach der Planpruefung, damit sie gegen den fertigen Plan rechnet")

  -- manifest.lua traegt sich selbst nicht in die Dateiliste ein -- genau
  -- die Datei, an der es im Feld gescheitert ist. Ihre Groesse muss
  -- gesondert dazugerechnet werden.
  assert_true(src:find("manifest_bytes", 1, true) ~= nil,
    "die Groesse des Manifests muss in die Berechnung eingehen")
end

print("installer_capacity_preflight_test.lua: ok")
