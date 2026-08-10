from pathlib import Path
import re
import zlib

root = Path('.')
manifest_path = root / 'xreactor/manifest.lua'
text = manifest_path.read_text(encoding='utf-8')

# Preserve every existing optional/feature/required_for flag and comment.
# Only the release metadata and the four actually changed manifest-managed
# runtime files get new size/hash values.
text = text.replace('-- xreactor/manifest.lua -- manifest-v514', '-- xreactor/manifest.lua -- manifest-v515', 1)
text = text.replace('manifest_version = 514', 'manifest_version = 515', 1)
text = text.replace('manifest_id = "manifest-v514"', 'manifest_id = "manifest-v515"', 1)

for rel in ['installer/init.lua', 'installer/journal.lua', 'start.lua', 'release.lua']:
    data = (root / 'xreactor' / rel).read_bytes()
    size = len(data)
    crc = f'{zlib.crc32(data) & 0xffffffff:08x}'
    lines = text.splitlines(True)
    matches = [i for i, line in enumerate(lines) if f'path = "{rel}"' in line]
    if len(matches) != 1:
        raise SystemExit(f'manifest entry for {rel}: expected exactly one line, got {len(matches)}')
    i = matches[0]
    line = lines[i]
    if len(re.findall(r'size_bytes\s*=\s*\d+', line)) != 1 or len(re.findall(r'hash\s*=\s*"[0-9a-f]+"', line)) != 1:
        raise SystemExit(f'manifest entry shape changed for {rel}: {line!r}')
    line = re.sub(r'size_bytes\s*=\s*\d+', f'size_bytes = {size}', line, count=1)
    line = re.sub(r'hash\s*=\s*"[0-9a-f]+"', f'hash = "{crc}"', line, count=1)
    lines[i] = line
    text = ''.join(lines)

manifest_path.write_text(text, encoding='utf-8')
print('phase3 manifest updated without changing optional semantics')
