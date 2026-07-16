-- tests/installer_manifest_files_same_ref_test.lua
--
-- INSTALL-P0 (docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md,
-- Abschnitt 14): Manifest und einzelne Dateien duerfen niemals innerhalb
-- desselben Installationslaufs aus unterschiedlichen Commits stammen.
--
-- Deckt drei unabhaengige Regressionsklassen ab:
--   1) http.lua's download_file() darf NICHT mehr automatisch, pro Datei,
--      auf den "beta"-Branch zurueckfallen, wenn ein konkreter Ref (SHA
--      oder explizit "beta") uebergeben wurde -- sonst koennte die Datei
--      von einem anderen Commit stammen als das (separat geladene)
--      Manifest.
--   2) installer/init.lua muss Manifest-URL und Datei-Downloads aus
--      DERSELBEN "ref"-Variable bauen (nicht Manifest hart auf "beta",
--      Dateien auf "sha").
--   3) Modularer Installer (xreactor/installer/*.lua) und monolithischer
--      Installer (/installer) muessen dieselbe Implementierung verwenden
--      (Audit-Vorgabe woertlich) -- die eingebetteten Kopien muessen
--      byte-identisch zu den Modul-Dateien sein, und der eigenstaendige
--      Bootstrap-Wrapper im monolithischen Installer muss dieselbe
--      Ref-Konsistenz zwischen Manifest und Dateien einhalten.

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
--    derselben "ref"-Variable gebaut werden.
-- ---------------------------------------------------------------------
do
  local init_src = read("xreactor/installer/init.lua")
  assert(init_src:find("local ref = sha or \"beta\"", 1, true),
    "installer/init.lua muss einen einzigen 'ref'-Wert (sha oder 'beta') fuer den gesamten Lauf bestimmen")
  assert(init_src:find("local manifest_url = GITHUB_RAW .. ref .. \"/xreactor/manifest.lua\"", 1, true),
    "installer/init.lua muss das Manifest von 'ref' laden, nicht hartcodiert von 'beta'")
  assert(init_src:find("stage_mod.install(file_list, INSTALL_ROOT, http_mod, ref,", 1, true),
    "installer/init.lua muss 'ref' (nicht 'sha') an stage_mod.install() durchreichen")
  -- Es darf keine hartcodierte, vom Ref losgeloeste Manifest-URL mehr geben.
  assert(not init_src:find("GITHUB_RAW .. \"beta/xreactor/manifest.lua\"", 1, true),
    "installer/init.lua darf die Manifest-URL nicht mehr hartcodiert auf 'beta' fixieren")
end

-- ---------------------------------------------------------------------
-- 3) Monolithischer Installer (/installer): eingebettete Kopien muessen
--    byte-identisch zu den Modul-Dateien sein, und der eigenstaendige
--    Bootstrap-Wrapper muss dieselbe Ref-Konsistenz einhalten.
-- ---------------------------------------------------------------------
do
  local mono = read("installer")

  local function extract_embedded(varname)
    local decl = varname .. " = [==["
    local decl_pos = mono:find(decl, 1, true)
    assert(decl_pos, "embedded block not found: " .. varname)
    local body_start = mono:find("%[==%[", decl_pos) + 4
    -- Lua strips exactly one leading newline right after a long-bracket
    -- opening delimiter -- mirror that here for a byte-accurate compare.
    if mono:sub(body_start, body_start) == "\n" then body_start = body_start + 1 end
    local body_end = mono:find("%]==%]", body_start)
    assert(body_end, "closing delimiter not found for: " .. varname)
    return mono:sub(body_start, body_end - 1)
  end

  local pairs_to_check = {
    { "local http_src",     "xreactor/installer/http.lua" },
    { "local manifest_src", "xreactor/installer/manifest.lua" },
    { "local stage_src",    "xreactor/installer/stage.lua" },
    { "local init_src",     "xreactor/installer/init.lua" },
  }
  for _, pair in ipairs(pairs_to_check) do
    local embedded = extract_embedded(pair[1])
    local modular = read(pair[2])
    assert(embedded == modular,
      "monolithischer Installer weicht von " .. pair[2] .. " ab -- Modularer und monolithischer Installer muessen dieselbe Implementierung verwenden (Audit-Vorgabe)")
  end

  -- Eigenstaendiger Bootstrap-Wrapper (der Code-Pfad, der bei einem
  -- tatsaechlichen "wget .../installer" + Ausfuehren wirklich laeuft --
  -- siehe Fix-Kommentar an dieser Stelle in der Datei selbst): muss
  -- "base" (fuer Datei-Downloads) und die Manifest-URL aus demselben
  -- "ref" bauen.
  assert(mono:find("local ref = sha or \"beta\"", 1, true),
    "monolithischer Installer-Wrapper muss einen einzigen 'ref'-Wert bestimmen")
  assert(mono:find("local base = GITHUB_RAW..ref..\"/xreactor/\"", 1, true),
    "monolithischer Installer-Wrapper muss 'base' aus 'ref' bauen (nicht separat aus 'sha')")
  assert(mono:find("local manifest_url = base..\"manifest.lua\"", 1, true),
    "monolithischer Installer-Wrapper muss die Manifest-URL aus 'base' (also aus 'ref') bauen")
  assert(not mono:find("GITHUB_RAW..\"beta/xreactor/manifest.lua\"", 1, true),
    "monolithischer Installer-Wrapper darf die Manifest-URL nicht mehr hartcodiert auf 'beta' fixieren")
end

print("installer_manifest_files_same_ref_test.lua: ok")
