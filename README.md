# XReactor Controller V3

XReactor is a distributed controller stack for **CC:Tweaked** systems connected to **Extreme Reactors** and optional support infrastructure. It is built around one **MASTER** computer and several specialized role nodes that manage hardware locally and exchange state over wireless modem channels.

The current repository ships:

- a **single-file installer** (`installer`) for fresh installs and updates,
- a role-based runtime under `/xreactor`,
- a startup entrypoint that launches the selected role automatically,
- per-role configs, local registries, telemetry, alerts, and monitor UIs.

## Schnellinstallation

Auf einem neuen CC:Tweaked-Computer mit aktivierter HTTP-API kann der Installer dauerhaft als `/installer` abgelegt und danach gestartet werden