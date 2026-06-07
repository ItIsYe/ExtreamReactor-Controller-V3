# XReactor Controller V3

XReactor is a distributed CC:Tweaked controller stack for Extreme Reactors and supporting infrastructure. It uses one MASTER computer and several role nodes. Hardware control stays local to the node that owns the peripherals; the MASTER coordinates state, setpoints, telemetry, alerts, and UI.

## Quick install

On a new CC:Tweaked computer with HTTP enabled, store the installer permanently and run it:

```sh
delete /installer
wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor