-- tests/sim/fixtures/reactor_normal_run.lua
-- Synthetische Fixture: normaler Reaktorlauf (60 Ticks, Rod=50%, stable temp).
-- Dient als Basis-Fixture bis erste echte In-game-Aufzeichnung vorliegt.
return {
  format_version = 1,
  node_id = "RT-1",
  role    = "RT-NODE",
  seed    = 42,
  ticks   = 60,
  dropped = 0,
  entries = {
    -- Peripheral-Calls: getCasingTemperature alle 5 Ticks
    {t=5,  kind="peripheral_call", data={name="reactor_0",method="getCasingTemperature",args={},result={350.2}}},
    {t=10, kind="peripheral_call", data={name="reactor_0",method="getCasingTemperature",args={},result={382.7}}},
    {t=15, kind="peripheral_call", data={name="reactor_0",method="getCasingTemperature",args={},result={401.1}}},
    {t=20, kind="peripheral_call", data={name="reactor_0",method="getCasingTemperature",args={},result={415.3}}},
    -- getFuelAmount
    {t=10, kind="peripheral_call", data={name="reactor_0",method="getFuelAmount",args={},result={3980}}},
    {t=20, kind="peripheral_call", data={name="reactor_0",method="getFuelAmount",args={},result={3960}}},
    -- Statuswechsel
    {t=1,  kind="state_change",   data={from="INIT",to="RUNNING",reason="startup"}},
    -- Entscheidungen: rod_level Anpassung
    {t=5,  kind="decision", data={kind="set_rod_level",value=50,context={temp=350.2}}},
    {t=15, kind="decision", data={kind="set_rod_level",value=52,context={temp=401.1}}},
    {t=20, kind="decision", data={kind="set_rod_level",value=52,context={temp=415.3}}},
    -- Modem TX
    {t=5,  kind="modem_tx", data={channel=6500,reply_channel=6501,message={type="status",temp=350.2}}},
    {t=10, kind="modem_tx", data={channel=6500,reply_channel=6501,message={type="status",temp=382.7}}},
  },
}
