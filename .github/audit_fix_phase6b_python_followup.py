from pathlib import Path

Path('tests/release_manifest_rt_guard_test.py').write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import re

root = Path('.')
release = (root / 'xreactor/release.lua').read_text(encoding='utf-8')
manifest = (root / 'xreactor/manifest.lua').read_text(encoding='utf-8')
installer = (root / 'installer').read_text(encoding='utf-8')
init = (root / 'xreactor/installer/init.lua').read_text(encoding='utf-8')
rt = (root / 'xreactor/nodes/rt/main.lua').read_text(encoding='utf-8')
paths = set(re.findall(r'path\s*=\s*"([^"]+)"', manifest))

def field(src, name):
    match = re.search(rf'{name}\s*=\s*"([^"]*)"', src)
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

for token in ['__xreactor_forced_ref', 'Erzwungener Recovery-Ref', 'recovery_origin_ref']:
    assert token in installer or token in init, f'installer immutable-ref contract missing {token}'
for token in ['resolved_commit_sha', 'installed_at', 'manifest_id', 'installer_ref']:
    assert token in init, f'installed commit metadata missing {token}'

print('release_manifest_rt_guard_test.py: ok')
''', encoding='utf-8')
print('phase6b final Python guard corrected')
