-- tests/cc_env_shim.lua
--
-- Minimaler CC:Tweaked-Kompatibilitaets-Shim fuer Offline-Testlaeufe (echtes
-- Host-Lua, keine Minecraft/CC:Tweaked-VM). Wird VOR jeder Testdatei geladen
-- (siehe tools/run_lua_tests.sh), damit Tests, die reale Produktionsmodule
-- per require()/dofile() einbinden, nicht an fehlenden CC:Tweaked-Globals
-- (os.epoch, colors) oder fehlendem package.path fuer xreactor/ scheitern.
-- Enthaelt bewusst KEINE Test-Logik und KEINE Annahmen ueber einzelne Tests --
-- nur die Umgebung, die echte Lua-Standardbibliotheken nicht mitbringen.

-- os.epoch("utc"/"local"/"ingame"): CC:Tweaked liefert Millisekunden seit
-- Epoch bzw. Ingame-Tageszeit. Fuer Offline-Tests genuegt eine echte,
-- monotone Millisekunden-Quelle -- die einzelnen Tests vergleichen nur
-- relative Zeitspannen, nie absolute Kalenderwerte.
if type(os.epoch) ~= "function" then
  function os.epoch(kind)
    if kind == "ingame" then
      return (os.time() % 24000)
    end
    return math.floor(os.time() * 1000 + (os.clock() * 1000) % 1000)
  end
end

-- colors: CC:Tweaked's Farb-API, echte Bitmask-Konstanten (16 Farben,
-- Bit 0..15) -- Werte entsprechen 1:1 der echten CC:Tweaked-API, falls ein
-- Test/Modul sie tatsaechlich als Bitmasken kombiniert.
if type(_G.colors) ~= "table" then
  _G.colors = {
    white     = 0x1,
    orange    = 0x2,
    magenta   = 0x4,
    lightBlue = 0x8,
    yellow    = 0x10,
    lime      = 0x20,
    pink      = 0x40,
    gray      = 0x80,
    lightGray = 0x100,
    cyan      = 0x200,
    purple    = 0x400,
    blue      = 0x800,
    brown     = 0x1000,
    green     = 0x2000,
    red       = 0x4000,
    black     = 0x8000,
  }
end

-- package.path: xreactor/-Module per require("nodes.rt.xyz") /
-- require("services.xyz") / require("shared.xyz") etc. auflösbar machen,
-- unabhaengig vom Arbeitsverzeichnis, aus dem der Test gestartet wird.
-- Tests, die ihr eigenes package.path bereits selbst vorne anfuegen,
-- funktionieren unveraendert weiter (sie haengen den hier gesetzten Wert
-- lediglich hinten an).
local repo_root = os.getenv("REPO_ROOT")
if not repo_root or repo_root == "" then repo_root = "."
end
package.path = table.concat({
  repo_root .. "/xreactor/?.lua",
  repo_root .. "/xreactor/?/init.lua",
  package.path,
}, ";")
