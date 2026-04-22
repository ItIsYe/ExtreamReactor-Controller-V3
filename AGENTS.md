# AGENTS.md

## Hard rules
- Never modify RT code or files under nodes/rt/.
- Preserve non-RT runtime behavior unless a change is necessary for stability or architecture.
- Prefer modular refactors over inline rewrites.
- Prefer payload -> ui_model -> rendering separation.
- Prefer shared support-node infrastructure for WATER/FUEL/REPROCESSOR.
- Keep installer externally compatible.

## Validation
- Run all relevant tests and checks after changes.
- If architecture changes significantly, add or update focused regression tests.
- Leave git worktree clean.
- Commit all final changes.

## Refactor goals
- Modularize ENERGY.
- Decouple MASTER.
- Introduce shared support runtime for WATER/FUEL/REPROCESSOR.
- Add shared non-RT config/payload/runtime building blocks.
- Keep RT untouched.
