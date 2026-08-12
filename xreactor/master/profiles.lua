-- Hinweis: ob Auto-Profile aktiv ist, steuert runtime.state.auto_profile
-- (siehe context.lua), nicht ein Feld hier in profiles.lua.
return {
  BASELOAD = { target = 0.6, ramp = "SLOW" },
  PEAK = { target = 1.0, ramp = "FAST" },
  IDLE = { target = 0.2, ramp = "SLOW" }
}
