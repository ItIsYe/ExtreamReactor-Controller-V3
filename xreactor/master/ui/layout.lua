-- xreactor/master/ui/layout.lua
--
-- Zentrales Layout-System (Schritt 1 des UI-Redesigns, 2026-07-01).
--
-- Warum dieses Modul existiert:
-- Vor diesem Modul berechnete jede View (overview.lua, rt_dashboard.lua,
-- monitor_ui.lua auf RT-Seite, ...) ihre Badge-Leisten unabhängig und live
-- beim Rendern — Badge-Text wurde einfach nacheinander geschrieben, ohne
-- vorher zu prüfen ob die Summe aller Badge-Breiten überhaupt auf den
-- Monitor passt. Ergebnis: auf schmalen Monitoren liefen Badges ineinander
-- oder wurden abgeschnitten, und jeder Fix davon war ein lokaler Sonderfall
-- statt eine strukturelle Lösung.
--
-- layout.lua kennt die Monitorbreite VORHER und entscheidet:
--   1. Passen alle Badges mit vollem Text? -> zeige sie so.
--   2. Passen sie nicht? -> kürze Text schrittweise (definierte Kurzformen).
--   3. Passen sie immer noch nicht? -> lasse die unwichtigsten Badges weg
--      (jedes Badge hat eine "priority", niedrige Priorität fliegt zuerst).
--
-- Damit kann KEIN Aufrufer mehr eine überlappende Badge-Leiste erzeugen,
-- weil die Breitenrechnung zentral und immer gleich passiert.

local ui = require("core.ui")
local colors = require("shared.colors")

local layout = {}

-- ── Interne Hilfsfunktionen ────────────────────────────────────────────────

local function clamp_int(value, min_v, max_v, fallback)
  local n = tonumber(value)
  if not n then n = fallback or min_v or 1 end
  n = math.floor(n)
  if min_v and n < min_v then n = min_v end
  if max_v and n > max_v then n = max_v end
  return n
end

local function fit(text, width)
  local raw = tostring(text or "")
  local w = clamp_int(width, 1, 512, #raw)
  if #raw <= w then return raw end
  if w <= 1 then return string.sub(raw, 1, w) end
  return string.sub(raw, 1, w - 1) .. "~"
end

-- ── Badge-Leiste mit garantierter Passform ────────────────────────────────
--
-- badges: Liste von { label = "MASTER", short = "MST", status = "OK",
--                      priority = 1 }
--   - label:    voller Text (bevorzugt angezeigt wenn Platz reicht)
--   - short:    Kurzform (Fallback wenn nicht genug Platz für label)
--   - status:   Statusfarbe ("OK"/"WARNING"/"EMERGENCY"/"LIMITED"/"muted"/...)
--   - priority: 1 = wichtigstes Badge (bleibt immer), höhere Zahl = fliegt
--               zuerst raus wenn nicht genug Platz ist. Default: Reihenfolge
--               in der Liste (erstes Element = höchste Prioritaet).
--
-- Gibt zurück: Anzahl tatsächlich gerenderter Badges, und ob gekürzt wurde
-- (fuer Diagnose/Logging, optional vom Aufrufer genutzt).
function layout.badge_row(mon, x, y, max_width, badges)
  local w = clamp_int(max_width, 3, 512, 20)
  badges = badges or {}

  -- Priorität normalisieren: fehlende priority = Listenposition
  local sorted = {}
  for i, b in ipairs(badges) do
    sorted[i] = {
      label = b.label or "",
      short = b.short or b.label or "",
      status = b.status or "OK",
      priority = b.priority or i,
      original_index = i,
    }
  end

  -- Versuch 1: alle Badges mit vollem Label, wenn's passt
  local function total_width(list, use_short)
    local total = 0
    for i, b in ipairs(list) do
      local text = use_short and b.short or b.label
      total = total + #text + (i < #list and 2 or 0)
    end
    return total
  end

  local render_list = sorted
  local use_short = false

  if total_width(sorted, false) > w then
    -- Versuch 2: alle Badges mit Kurzform
    use_short = true
    if total_width(sorted, true) > w then
      -- Versuch 3: niedrigste Prioritaet zuerst entfernen, bis es passt
      local remaining = {}
      for _, b in ipairs(sorted) do remaining[#remaining + 1] = b end
      table.sort(remaining, function(a, b) return a.priority < b.priority end)

      while #remaining > 1 and total_width(remaining, true) > w do
        table.remove(remaining) -- letztes = niedrigste Prioritaet raus
      end
      -- Zurück in Original-Reihenfolge sortieren fuer stabile Anzeige
      table.sort(remaining, function(a, b) return a.original_index < b.original_index end)
      render_list = remaining
    end
  end

  -- Rendern
  local col = x
  local rendered = 0
  for _, b in ipairs(render_list) do
    local text = use_short and b.short or b.label
    if col + #text > x + w then break end
    ui.badge(mon, col, y, text, b.status)
    col = col + #text + 2
    rendered = rendered + 1
  end

  return rendered, (rendered < #badges)
end

-- ── Standard-Statusleiste für RT/Energy/Master-Node-Screens ──────────────
--
-- Baut die typische "RT OK | M OK | MASTER | CAP | SHD"-Leiste aus
-- semantischen Eingaben, statt dass jeder Aufrufer Kurzformen von Hand
-- erfindet. Zentrale Stelle für Kurzform-Konventionen.
function layout.status_badges(opts)
  opts = opts or {}
  local badges = {}

  if opts.health then
    badges[#badges + 1] = {
      label = "RT " .. tostring(opts.health),
      short = "RT",
      status = opts.health,
      priority = 1,
    }
  end
  if opts.master_state then
    badges[#badges + 1] = {
      label = "M " .. tostring(opts.master_state),
      short = "M",
      status = opts.master_status or "OK",
      priority = 1,
    }
  end
  if opts.mode then
    badges[#badges + 1] = {
      label = tostring(opts.mode),
      short = tostring(opts.mode):sub(1, 3),
      status = opts.mode_status or "OK",
      priority = 2,
    }
  end
  if opts.capacity_ready ~= nil then
    badges[#badges + 1] = {
      label = opts.capacity_ready and "CAP" or "LEARN",
      short = opts.capacity_ready and "CAP" or "LRN",
      status = opts.capacity_status or (opts.capacity_ready and "OK" or "LIMITED"),
      priority = 3,
    }
  end
  if opts.assignment_state then
    local a = tostring(opts.assignment_state)
    if a == "shed" or a == "shutdown" then
      badges[#badges + 1] = { label = "SHED", short = "SHD", status = "WARNING", priority = 2 }
    elseif a == "startup" then
      badges[#badges + 1] = { label = "STARTUP", short = "SRT", status = "LIMITED", priority = 2 }
    end
  end

  return badges
end

return layout
