local restart_cooldown_ms = 15000
local stability_ms = 1500

local workflow = {
  cancelled_at = 1000,
  shutdown_candidate_since = 1000,
  requested_at = nil
}

local function evaluate(now)
  workflow.shutdown_candidate_since = workflow.shutdown_candidate_since or now
  local candidate_age_ms = now - workflow.shutdown_candidate_since
  if workflow.cancelled_at and (now - workflow.cancelled_at) < restart_cooldown_ms then
    workflow.shutdown_candidate_since = now
    return 'COOLDOWN'
  elseif candidate_age_ms < stability_ms then
    return 'STABILITY'
  elseif not workflow.requested_at then
    workflow.requested_at = now
    return 'START'
  end
  return 'NONE'
end

if evaluate(2000) ~= 'COOLDOWN' then
  error('expected cooldown guard to suppress immediate restart')
end
if evaluate(16000) ~= 'STABILITY' then
  error('expected extra stability window after cooldown release')
end
if evaluate(17600) ~= 'START' then
  error('expected shutdown restart only after stability window elapsed post-cooldown')
end

print('master_shutdown_cooldown_stability_semantics_test.lua: ok')
