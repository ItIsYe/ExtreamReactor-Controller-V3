from pathlib import Path
import re
p=Path('xreactor/nodes/rt/main.lua')
lines=p.read_text(encoding='utf-8').splitlines()
starts=[]
for i,line in enumerate(lines,1):
    if re.match(r'^local function ',line) or re.match(r'^function ',line):
        name=re.sub(r'^(?:local )?function\s+','',line).split('(',1)[0]
        starts.append((i,name))
starts.append((len(lines)+2,'<EOF>'))
for (line,name),(nxt,_) in zip(starts,starts[1:]):
    print(f'{line:4d}-{nxt-1:4d} span={nxt-line:3d} {name}')
