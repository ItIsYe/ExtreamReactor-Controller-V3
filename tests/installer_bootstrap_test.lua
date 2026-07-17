-- tests/installer_bootstrap_test.lua
--
-- Regression test fuer INSTALL-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 8, "Zwei unabhaengige Installer-
-- implementierungen"). /installer traegt keine eingebetteten Textkopien
-- und keine eigene Installationslogik mehr -- es loest genau EINEN Ref
-- auf, laedt die kanonischen Installermodule GENAU dieses Refs frisch
-- herunter, und fuehrt AUSSCHLIESSLICH installer/init.lua (als Funktion
-- mit injizierten Abhaengigkeiten) damit aus.
--
-- Treibt das echte /installer mit einem gemockten http/os: jede der 6
-- Modul-Downloads und der init.lua-Download werden ueber einen Fake-
-- HTTP-Server aus demselben aufgeloesten Ref bedient; das (ebenfalls
-- gefakte) init.lua zeichnet auf, mit welchem deps-Table es aufgerufen
-- wurde, statt eine echte Installation durchzufuehren. Verifiziert: (1)
-- alle Downloads verwenden denselben aufgeloesten Ref, (2) deps enthaelt
-- alle sechs erwarteten Module plus ref, (3) ein fehlgeschlagener Modul-
-- Download bricht VOR jedem init.lua-Aufruf kontrolliert ab, (4) nach
-- erfolgreichem init.lua-Aufruf wird rebootet.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

local repo_root = os.getenv("REPO_ROOT") or "."
local installer_src = read_file(repo_root .. "/installer")

local FAKE_SHA = "abc123def4567890abc123def4567890abc123d"
local GITHUB_API = "https://api.github.com/repos/ItIsYe/ExtreamReactor-Controller-V3/branches/beta"
local GITHUB_RAW = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

local MODULE_NAMES = { "http", "manifest", "stage", "ui", "journal", "plan_validator" }

-- Liefert fuer jedes Modul einen minimalen, aber gueltigen Modul-Body
-- (return { name = "..." }), damit load_module() es tatsaechlich laden
-- kann, ohne eine echte Installermodul-Implementierung zu benoetigen.
local function fake_module_body(name)
  return "return { __fake_module = " .. string.format("%q", name) .. " }"
end

-- Zeichnet auf, mit welchem deps-Table init.lua aufgerufen wurde, statt
-- eine echte Installation durchzufuehren.
local FAKE_INIT_SRC = [[
return function(deps)
  _G.__captured_deps = deps
end
]]

local function run_bootstrap(opts)
  opts = opts or {}
  local requested_urls = {}
  local reboot_calls = 0
  local sleep_calls = 0

  _G.__captured_deps = nil
  _G.http = {
    get = function(url)
      requested_urls[#requested_urls + 1] = url
      if url == GITHUB_API then
        return {
          readAll = function() return '{"sha":"' .. FAKE_SHA .. '"}' end,
          close = function() end,
        }
      end
      local base = GITHUB_RAW .. FAKE_SHA .. "/xreactor/"
      for _, name in ipairs(MODULE_NAMES) do
        if url == base .. "installer/" .. name .. ".lua" then
          if opts.fail_module == name then
            return nil
          end
          return {
            readAll = function() return fake_module_body(name) end,
            close = function() end,
          }
        end
      end
      if url == base .. "installer/init.lua" then
        if opts.fail_init then return nil end
        return {
          readAll = function() return FAKE_INIT_SRC end,
          close = function() end,
        }
      end
      return nil
    end,
  }
  _G.os = _G.os or {}
  os.reboot = function() reboot_calls = reboot_calls + 1 end
  os.sleep = function() sleep_calls = sleep_calls + 1 end
  os.epoch = os.epoch or function() return 0 end
  local orig_print = print
  _G.print = function() end

  local chunk, lerr = load(installer_src, "=installer", "t")
  if not chunk then error("installer failed to parse: " .. tostring(lerr)) end
  local ok, err = pcall(chunk)
  _G.print = orig_print

  return ok, err, requested_urls, reboot_calls, sleep_calls
end

-- 1. Erfolgreicher Lauf: alle Downloads verwenden denselben aufgeloesten
--    Ref, deps enthaelt alle sechs Module plus ref, init.lua wird
--    tatsaechlich mit diesen deps aufgerufen, danach wird rebootet.
do
  local ok, err, urls, reboot_calls = run_bootstrap()
  if not ok then error("expected the bootstrap to succeed, got error: " .. tostring(err)) end

  local base = GITHUB_RAW .. FAKE_SHA .. "/xreactor/"
  for _, name in ipairs(MODULE_NAMES) do
    local expected_url = base .. "installer/" .. name .. ".lua"
    local found = false
    for _, u in ipairs(urls) do if u == expected_url then found = true end end
    if not found then
      error("expected a download of " .. expected_url .. " (same resolved ref as every other file), never happened")
    end
  end

  local deps = _G.__captured_deps
  if not deps then error("installer/init.lua (fake) was never invoked") end
  if deps.ref ~= FAKE_SHA then
    error("expected deps.ref to be the resolved SHA, got: " .. tostring(deps.ref))
  end
  for _, name in ipairs(MODULE_NAMES) do
    local dep_key = name .. "_mod"
    local mod = deps[dep_key]
    if type(mod) ~= "table" or mod.__fake_module ~= name then
      error("expected deps." .. dep_key .. " to be the loaded '" .. name .. "' module, got: " .. tostring(mod))
    end
  end

  if reboot_calls ~= 1 then
    error("expected exactly one os.reboot() call after a successful install, got " .. reboot_calls)
  end
  _G.__captured_deps = nil
end

-- 2. Ein fehlschlagender Modul-Download muss den Bootstrap kontrolliert
--    abbrechen, BEVOR init.lua ueberhaupt aufgerufen wird -- niemals eine
--    Installation mit einem fehlenden Kernmodul versuchen.
do
  local ok, err = run_bootstrap({ fail_module = "stage" })
  if ok then
    error("CRITICAL: bootstrap did not abort when installer/stage.lua could not be downloaded")
  end
  if not tostring(err):find("stage", 1, true) then
    error("expected the error to mention the failed module 'stage', got: " .. tostring(err))
  end
  if _G.__captured_deps ~= nil then
    error("CRITICAL: init.lua was invoked despite a missing core module")
  end
end

-- 3. Ein fehlschlagender init.lua-Download muss ebenfalls kontrolliert
--    abbrechen.
do
  local ok, err = run_bootstrap({ fail_init = true })
  if ok then
    error("CRITICAL: bootstrap did not abort when installer/init.lua could not be downloaded")
  end
  if not tostring(err):find("init", 1, true) then
    error("expected the error to mention init.lua, got: " .. tostring(err))
  end
end

print("installer_bootstrap_test.lua: ok")
