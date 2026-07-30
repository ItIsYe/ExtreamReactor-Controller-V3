package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL/MANIFEST-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 7 "Vorabvalidierung ist zu schwach").
-- Die im Audit geforderte "transitive require()/dofile()-Abdeckung" laesst
-- sich nicht als reiner Laufzeit-Guard umsetzen (installer/plan_validator.lua
-- kennt vor dem Download nur Pfade/Groessen/Hashes, nicht den Dateiinhalt).
-- Stattdessen wird hier, gegen den ECHTEN lokalen Quelltext, geprueft: fuer
-- jede Rolle wird ueber die echte installer/manifest.lua's files_for_role()
-- die Pflicht-Dateimenge bestimmt (ohne optionale Features); jede .lua-Datei
-- darin wird nach require("...")/dofile("/xreactor/....lua")-Aufrufen
-- durchsucht, und jedes aufgeloeste Ziel, das als echte Datei im Repo
-- existiert, MUSS entweder selbst in derselben Pflicht-Dateimenge enthalten
-- sein oder ueber pcall(...) als bewusst optionale Abhaengigkeit markiert
-- sein (etablierte Konvention in diesem Code, z.B. pcall(require,
-- "optional.speaker_alarm")).

local manifest_mod = require('installer.manifest')

local repo_root = os.getenv('REPO_ROOT') or '.'

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local c = f:read('*a')
  f:close()
  return c
end

local function file_exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

local manifest = assert(loadfile(repo_root .. '/xreactor/manifest.lua'))()

local ROLES = { 'MASTER', 'RT', 'ENERGY', 'WATER', 'FUEL', 'VALVE', 'REPROCESSING', 'LOG_COLLECTOR' }

-- require("a.b.c") -> "a/b/c.lua"
local function resolve_require(mod_name)
  return (mod_name:gsub('%.', '/')) .. '.lua'
end

-- dofile("/xreactor/a/b.lua") -> "a/b.lua"
local function resolve_dofile(arg)
  return arg:match('^/xreactor/(.+)$')
end

-- Etablierte Konvention in diesem Code fuer bewusst optionale/best-effort
-- Abhaengigkeiten: pcall(require, "...") / pcall(dofile, "..."), immer in
-- derselben Zeile. Solche Fundstellen sind KEIN Manifest-Luecken-Befund.
local function line_is_pcall_wrapped(line)
  return line:find('pcall%s*%(%s*require%s*,') ~= nil
      or line:find('pcall%s*%(%s*dofile%s*,') ~= nil
end

-- "--"-Kommentare abschneiden, BEVOR nach require()/dofile() gesucht wird
-- -- sonst wuerden Kommentarzeilen, die beispielhaft eine require()-Stelle
-- erwaehnen (z.B. in manifest.lua's eigenen Dokumentationskommentaren),
-- faelschlich als echte Codeaufrufe gezaehlt. Einfache Heuristik (kein
-- vollstaendiger Lua-Parser): in diesem Codebase steht "--" nie innerhalb
-- einer fuer diesen Test relevanten require()/dofile()-Pfadangabe.
local function strip_comment(line)
  local idx = line:find('%-%-')
  if idx then return line:sub(1, idx - 1) end
  return line
end

local failures = {}

for _, role in ipairs(ROLES) do
  local expected = manifest_mod.files_for_role(manifest, role, {})
  for path in pairs(expected) do
    if path:sub(-4) == '.lua' then
      local content = read_file(repo_root .. '/xreactor/' .. path)
      if content then
        for raw_line in (content .. '\n'):gmatch('([^\n]*)\n') do
          local line = strip_comment(raw_line)
          if not line_is_pcall_wrapped(line) then
            for mod_name in line:gmatch('require%s*%(%s*["\']([%w_.]+)["\']%s*%)') do
              local target = resolve_require(mod_name)
              if not expected[target] and file_exists(repo_root .. '/xreactor/' .. target) then
                failures[#failures + 1] = string.format(
                  '[%s] %s requires %q (-> %s), but that file is not part of %s mandatory manifest file set',
                  role, path, mod_name, target, role)
              end
            end
            for arg in line:gmatch('dofile%s*%(%s*["\'](/xreactor/[%w_./]+%.lua)["\']%s*%)') do
              local target = resolve_dofile(arg)
              if target and not expected[target] and file_exists(repo_root .. '/xreactor/' .. target) then
                failures[#failures + 1] = string.format(
                  '[%s] %s dofile()s %q (-> %s), but that file is not part of %s mandatory manifest file set',
                  role, path, arg, target, role)
              end
            end
          end
        end
      end
    end
  end
end

if #failures > 0 then
  error('transitive require()/dofile() manifest coverage gaps found:\n  ' .. table.concat(failures, '\n  '))
end

print('manifest_transitive_require_coverage_test.lua: ok')
