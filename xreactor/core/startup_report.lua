-- xreactor/core/startup_report.lua
--
-- Kernfunktion (NICHT optional, 2026-07-01): kompakter Startup-Diagnose-
-- Report. War zunaechst in xreactor/optional/ eingeordnet, gehoert aber
-- fest zur Kernfunktionalitaet und soll auf jedem Node ohne Opt-in
-- installiert werden — daher nach core/ verschoben.
--
-- Zweck: beim Boot eines Nodes eine einzige, klar lesbare Zusammenfassung
-- ausgeben (Modem gefunden? Config valide? Peripherals erkannt? Rolle
-- korrekt geladen?), statt dass diese Informationen ueber viele einzelne
-- Log-Zeilen verstreut sind, die man erst zusammensuchen muss.
--
-- Rollenuebergreifend nutzbar (RT/ENERGY/FUEL/WATER/REPROCESSOR/MASTER/LOG)
-- — jeder Aufrufer uebergibt einfach die Checks, die fuer seine Rolle
-- relevant sind. Vollstaendig fehlerisoliert: ein Fehler in diesem Modul
-- kann den eigentlichen Boot-Vorgang nicht verzoegern oder blockieren.

local M = {}

-- run(checks, opts): checks ist eine Liste von
--   { name = "Modem", ok = true/false, detail = "optionaler Zusatztext" }
-- opts.log ist die Log-Funktion des Aufrufers (z.B. ctx.log). Gibt
-- (all_ok, report_text) zurueck — all_ok ist false wenn mindestens ein
-- Check fehlgeschlagen ist, report_text ist die komplette, mehrzeilige
-- Zusammenfassung (auch fuer den Fall dass der Aufrufer sie zusaetzlich
-- selbst irgendwo anzeigen will, z.B. auf einem Monitor).
function M.run(checks, opts)
  opts = opts or {}
  checks = checks or {}
  local ok_result, all_ok, report_text = pcall(function()
    local lines = { "=== Startup-Diagnose ===" }
    local ok_flag = true
    local fail_count = 0
    for _, check in ipairs(checks) do
      local status = check.ok and "OK" or "FEHLT"
      if not check.ok then
        ok_flag = false
        fail_count = fail_count + 1
      end
      local line = string.format("  [%s] %s", status, tostring(check.name or "?"))
      if check.detail and tostring(check.detail) ~= "" then
        line = line .. " — " .. tostring(check.detail)
      end
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = string.format("=== %d/%d Checks OK ===", #checks - fail_count, #checks)
    local text = table.concat(lines, "\n")
    if opts.log then
      for _, line in ipairs(lines) do
        pcall(opts.log, "INFO", line)
      end
    end
    return ok_flag, text
  end)
  if not ok_result then
    -- Selbst wenn dieses Diagnose-Feature intern einen Fehler wirft, darf
    -- das den Boot-Vorgang nicht stoppen — Rueckgabe eines neutralen
    -- "alles unbekannt"-Ergebnisses statt einer Exception nach aussen.
    return true, "Startup-Diagnose nicht verfuegbar (interner Fehler)"
  end
  return all_ok, report_text
end

-- Hilfsfunktion: baut einen Standard-Check fuer "ist ein wireless Modem
-- vorhanden" — von fast jeder Rolle nutzbar, spart Boilerplate im Aufrufer.
function M.check_wireless_modem()
  local ok = pcall(function()
    if not peripheral or type(peripheral.getNames) ~= "function" then return false end
    local names = peripheral.getNames()
    for _, name in ipairs(names) do
      local ptype = peripheral.getType(name)
      if tostring(ptype):find("modem", 1, true) then
        local modem = peripheral.wrap(name)
        if modem and type(modem.isWireless) == "function" and modem.isWireless() then
          return true
        end
      end
    end
    return false
  end)
  local found = ok
  return { name = "Ender Modem", ok = found == true, detail = found and nil or "kein wireless Modem gefunden" }
end

return M
