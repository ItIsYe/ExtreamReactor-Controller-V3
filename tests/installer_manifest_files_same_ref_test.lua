-- tests/installer_manifest_files_same_ref_test.lua
--
-- INSTALL-P0 (docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md,
-- Abschnitt 14): Manifest und einzelne Dateien duerfen niemals innerhalb
-- desselben Installationslaufs aus unterschiedlichen Commits stammen.
--
-- Deckt zwei unabhaengige Regressionsklassen ab:
--   1) http.lua's download_file() darf NICHT mehr automatisch, pro Datei,
--      auf den "beta"-Branch zurueckfallen, wenn ein konkreter Ref (SHA
--      oder explizit "beta") uebergeben wurde -- sonst koennte die Datei
--      von einem anderen Commit stammen als das (separat geladene)
--      Manifest.
--   2) installer/init.lua muss Manifest-URL und Datei-Downloads aus
--      DEMSELBEN, vom Aufrufer per deps.ref uebergebenen "ref"-Wert bauen
--      (nicht Manifest hart auf "beta", Dateien auf einen selbst
--      aufgeloesten "sha" -- seit INSTALL-P1/Abschnitt 8 loest
--      installer/init.lua selbst KEINEN Ref mehr auf, siehe
--      installer_bootstrap_test.lua fuer die Ref-Konsistenz zwischen dem
--      duennen /installer-Bootstrap und den heruntergeladenen
--      Installermodulen).

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

-- ---------------------------------------------------------------------
-- 1) http.lua: download_file(rel, ref) darf bei fehlschlagender,
--    konkret gepinnter ref NICHT still auf "beta" ausweichen.
-- ---------------------------------------------------------------------
local function make_fake_http(beta_ok)
  local calls = {}
  local fake = {
    get = function(url)
      calls[#calls + 1] = url
      if beta_ok and url:find("/beta/xreactor/", 1, true) then
        return {
          readAll = function() return "return {ok=true}" end,
          close = function() end,
          getResponseCode = function() return 200 end,
        }
      end
      return nil
    end,
  }
  return fake, calls
end

local function load_http_mod(fake_http)
  local src = read("xreactor/installer/http.lua")
  local env = setmetatable({
    http = fake_http,
    os = { epoch = function() return 0 end, sleep = function() end, time = os.time },
  }, { __index = _G })
  local fn = assert(load(src, "=http_test", "t", env))
  return fn()
end

do
  local fake_http, calls = make_fake_http(true)
  local http_mod = load_http_mod(fake_http)

  -- Ein konkret gepinnter (fehlschlagender) Ref darf NICHT durch einen
  -- automatischen Beta-Fallback "gerettet" werden.
  calls = {}
  local body = http_mod.download_file("manifest.lua", "deadbeef0000", { retries = 1 })
  assert(body == nil,
    "download_file() darf bei fehlschlagendem SHA-Ref nicht automatisch auf 'beta' ausweichen (Datei koennte dann von einem anderen Commit stammen als das Manifest)")
  for _, u in ipairs(calls) do
    assert(not u:find("/beta/", 1, true),
      "download_file() mit explizitem SHA-Ref darf niemals eine 'beta'-URL versuchen: " .. u)
  end

  -- Ref == "beta" (explizit vom Aufrufer gewaehlt, z.B. weil resolve_sha()
  -- fehlgeschlagen ist) muss weiterhin funktionieren.
  calls = {}
  local body2 = http_mod.download_file("manifest.lua", "beta", { retries = 1 })
  assert(body2 == "return {ok=true}", "download_file() mit ref='beta' muss weiterhin funktionieren")
end

-- ---------------------------------------------------------------------
-- 2) installer/init.lua: Manifest-URL und Datei-Installation muessen aus
--    demselben, vom Aufrufer uebergebenen "ref"-Wert gebaut werden.
-- ---------------------------------------------------------------------
do
  local init_src = read("xreactor/installer/init.lua")
  assert(init_src:find("local ref = deps.ref", 1, true),
    "installer/init.lua muss 'ref' vom Aufrufer uebernehmen (deps.ref) statt ihn selbst aufzuloesen")
  assert(init_src:find("local manifest_url = GITHUB_RAW .. ref .. \"/xreactor/manifest.lua\"", 1, true),
    "installer/init.lua muss das Manifest von 'ref' laden, nicht hartcodiert von 'beta'")
  assert(init_src:find("stage_mod.install(file_list, INSTALL_ROOT, http_mod, ref,", 1, true),
    "installer/init.lua muss 'ref' (nicht 'sha') an stage_mod.install() durchreichen")
  -- Es darf keine hartcodierte, vom Ref losgeloeste Manifest-URL mehr geben.
  assert(not init_src:find("GITHUB_RAW .. \"beta/xreactor/manifest.lua\"", 1, true),
    "installer/init.lua darf die Manifest-URL nicht mehr hartcodiert auf 'beta' fixieren")
end

print("installer_manifest_files_same_ref_test.lua: ok")
