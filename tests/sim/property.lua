-- tests/sim/property.lua  Phase 9.1
-- Schlanke Property-Test-Bibliothek: forAll + shrink.

local M = {}
M.DEFAULT_TRIALS = 100

-- Zufallsgeneratoren
M.gen = {}

function M.gen.int(lo, hi)
  lo = lo or 0; hi = hi or 100
  return function(rng) return lo + math.floor(rng() * (hi - lo + 1)) end
end

function M.gen.float(lo, hi)
  lo = lo or 0.0; hi = hi or 1.0
  return function(rng) return lo + rng() * (hi - lo) end
end

function M.gen.bool()
  return function(rng) return rng() < 0.5 end
end

function M.gen.one_of(values)
  return function(rng)
    local i = 1 + math.floor(rng() * #values)
    return values[math.max(1, math.min(#values, i))]
  end
end

function M.gen.tuple(gens)
  return function(rng)
    local t = {}
    for i, g in ipairs(gens) do t[i] = g(rng) end
    return t
  end
end

-- Einfaches Shrinking: halbiere numerische Werte
local function shrink_value(v)
  if type(v) == "number" then
    if v == 0 then return {} end
    return { math.floor(v / 2), -math.floor(v / 2), 0 }
  end
  if type(v) == "boolean" then return { not v } end
  if type(v) == "table" then
    local result = {}
    for i = 1, #v do
      local sub = {}
      for j = 1, #v do if j ~= i then sub[#sub+1] = v[j] end end
      result[#result+1] = sub
    end
    return result
  end
  return {}
end

-- forAll(gen, prop, opts) → { ok, counterexample, trials, shrinks }
function M.forAll(gen, prop, opts)
  opts = opts or {}
  local trials   = opts.trials  or M.DEFAULT_TRIALS
  local seed     = opts.seed    or 42
  local max_shrinks = opts.max_shrinks or 50

  math.randomseed(seed)
  local rng = math.random

  local counterexample = nil
  local shrink_count   = 0

  for i = 1, trials do
    local input = gen(rng)
    local ok, err = pcall(prop, input)
    if not ok then
      counterexample = { input = input, error = err, trial = i }
      -- Minimales Shrinking
      local candidates = shrink_value(input)
      local k = 0
      while k < max_shrinks and #candidates > 0 do
        local next_candidates = {}
        local shrunk = false
        for _, candidate in ipairs(candidates) do
          local ok2, err2 = pcall(prop, candidate)
          if not ok2 then
            counterexample = { input = candidate, error = err2, trial = i, shrunk = true }
            for _, s in ipairs(shrink_value(candidate)) do
              next_candidates[#next_candidates+1] = s
            end
            shrunk = true
            shrink_count = shrink_count + 1
            break
          end
        end
        if not shrunk then break end
        candidates = next_candidates
        k = k + 1
      end
      return { ok = false, counterexample = counterexample,
               trials = i, shrinks = shrink_count }
    end
  end

  return { ok = true, trials = trials, shrinks = 0 }
end

-- check(name, gen, prop, opts) — Kurzform mit assert
function M.check(name, gen, prop, opts)
  local result = M.forAll(gen, prop, opts)
  if not result.ok then
    local ce = result.counterexample
    error(string.format(
      "Property '%s' FAILED after %d trials (shrinks=%d)\n  input: %s\n  error: %s",
      name, result.trials, result.shrinks,
      tostring(ce and ce.input), tostring(ce and ce.error)
    ), 2)
  end
  return result
end

return M
