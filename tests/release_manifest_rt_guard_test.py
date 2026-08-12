#!/usr/bin/env python3
from pathlib import Path
import re

root = Path('.')
release = (root / 'xreactor/release.lua').read_text(encoding='utf-8')
manifest = (root / 'xreactor/manifest.lua').read_text(encoding='utf-8')
installer = (root / 'installer').read_text(encoding='utf-8')
installer_init = (root / 'xreactor/installer/init.lua').read_text(encoding='utf-8')
installer_http = (root / 'xreactor/installer/http.lua').read_text(encoding='utf-8')
rt = (root / 'xreactor/nodes/rt/main.lua').read_text(encoding='utf-8')
paths = set(re.findall(r'path\s*=\s*"([^"]+)"', manifest))


def field(source, name):
    match = re.search(rf'{name}\s*=\s*"([^"]*)"', source)
    if not match:
        raise AssertionError(f'missing {name}')
    return match.group(1)


assert field(release, 'source_ref') == 'beta'
assert field(manifest, 'source_ref') == 'beta'
assert field(release, 'commit_sha') in ('', 'beta')

for path in ['nodes/rt/discovery_runtime.lua', 'nodes/rt/health_payload.lua', 'nodes/rt/main.lua']:
    assert path in paths, f'manifest missing RT runtime file {path}'

require_pattern = re.compile(r"require\s*\(\s*['\"]([\w\._]+)['\"]\s*\)")
for module in require_pattern.findall(rt):
    rel = module.replace('.', '/') + '.lua'
    if (root / 'xreactor' / rel).exists():
        assert rel in paths, f'RT require missing from manifest: {rel}'

assert '__xreactor_forced_ref' in installer
assert 'or "beta"' in installer
assert 'local ref = deps.ref' in installer_init
assert 'manifest_mod.crc32' in installer_init
assert 'resolve_sha' not in installer + installer_init + installer_http
assert 'api.github.com' not in installer + installer_init + installer_http

print('release_manifest_rt_guard_test.py: ok')
