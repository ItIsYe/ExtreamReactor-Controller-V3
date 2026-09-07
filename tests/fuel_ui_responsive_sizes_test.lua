-- The FUEL UI is intentionally no longer responsive. Its SCADA contract is
-- one exact 82x40 monitor. Reuse the exhaustive fixed-size render/touch harness.
dofile('tests/fuel_scada_render_harness.lua')
print('fuel_ui_responsive_sizes_test.lua: ok (fixed 82x40 contract)')
