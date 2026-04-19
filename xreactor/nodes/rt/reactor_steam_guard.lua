local safety = require("core.safety")

local M = {}

local function clamp_ratio(value)
  if type(value) ~= "number" then
    return nil
  end
  return safety.clamp(value, 0, 1)
end

function M.apply(current_rods, target_rods, steam_fill_ratio, cfg, state)
  state = state or {}
  cfg = cfg or {}

  local alpha = tonumber(cfg.ema_alpha) or 0.2
  if alpha <= 0 or alpha >= 1 then
    alpha = 0.2
  end

  local ratio = clamp_ratio(steam_fill_ratio)
  local ema_ratio = state.ema_ratio
  if ratio ~= nil then
    if type(ema_ratio) == "number" then
      ema_ratio = ema_ratio + (ratio - ema_ratio) * alpha
    else
      ema_ratio = ratio
    end
    state.ema_ratio = ema_ratio
    state.last_ratio = ratio
  end

  local high_on = tonumber(cfg.high_ratio) or 0.82
  local high_off = tonumber(cfg.high_release_ratio) or 0.74
  local critical_on = tonumber(cfg.critical_ratio) or 0.92
  local critical_off = tonumber(cfg.critical_release_ratio) or 0.86
  local force_close_step = math.max(0, math.floor(tonumber(cfg.force_close_step) or 2))

  local high_active = state.high_active == true
  local critical_active = state.critical_active == true
  local eval_ratio = ema_ratio
  if type(eval_ratio) == "number" then
    if critical_active then
      if eval_ratio <= critical_off then
        critical_active = false
      end
    elseif eval_ratio >= critical_on then
      critical_active = true
    end

    if critical_active then
      high_active = true
    elseif high_active then
      if eval_ratio <= high_off then
        high_active = false
      end
    elseif eval_ratio >= high_on then
      high_active = true
    end
  end

  state.high_active = high_active
  state.critical_active = critical_active

  local adjusted_target = target_rods
  local opening_requested = type(target_rods) == "number" and type(current_rods) == "number" and target_rods < current_rods
  local blocked_opening = false
  local forced_closing = false

  if high_active and opening_requested then
    adjusted_target = current_rods
    blocked_opening = true
  end

  if critical_active and type(current_rods) == "number" then
    local critical_floor = current_rods + force_close_step
    if type(adjusted_target) ~= "number" or adjusted_target < critical_floor then
      adjusted_target = critical_floor
      forced_closing = true
    end
  end

  return adjusted_target, {
    raw_ratio = ratio,
    ema_ratio = ema_ratio,
    high_active = high_active,
    critical_active = critical_active,
    blocked_opening = blocked_opening,
    forced_closing = forced_closing,
    unavailable = ratio == nil
  }
end

return M
