"""Static geometry proof for every visible touch surface in the fixed 82x40 FUEL UI."""
from dataclasses import dataclass

W, H = 82, 40

@dataclass(frozen=True)
class R:
    name: str
    x1: int
    y1: int
    x2: int
    y2: int
    def inside(self): return 1 <= self.x1 <= self.x2 <= W and 1 <= self.y1 <= self.y2 <= H
    def overlap(self, o):
        return not (self.x2 < o.x1 or o.x2 < self.x1 or self.y2 < o.y1 or o.y2 < self.y1)

def button(name, x, y, w, h): return R(name, x, y, x + w - 1, y + h - 1)

def assert_group(name, rects):
    for r in rects:
        assert r.inside(), f'{name}: outside screen: {r}'
    for i, a in enumerate(rects):
        for b in rects[i+1:]:
            assert not a.overlap(b), f'{name}: touch surfaces overlap: {a} / {b}'

# Shared footer: smaller 15x2 buttons.
assert_group('footer', [button('back', 3, 38, 15, 2), button('next', 65, 38, 15, 2)])

# Details reactor navigation.
assert_group('details-nav', [button('reactor-prev', 3, 5, 13, 2), button('reactor-next', 67, 5, 13, 2)])

# Overview >16 reactor paging.
assert_group('overview-page', [button('fleet-prev', 3, 33, 13, 2), button('fleet-next', 67, 33, 13, 2)])

# Router list.
list_fixed = [
    button('logistics', 2, 5, 14, 2),
    button('export', 18, 5, 35, 2),
    button('learn', 57, 5, 22, 2),
    button('page-prev', 5, 29, 12, 2),
    button('page-next', 66, 29, 12, 2),
    button('save', 22, 33, 18, 2),
    button('discard', 44, 33, 16, 2),
]
assert_group('router-list-fixed', list_fixed)
reactor_actions = [button(f'reactor-{i+1}', 70, 12 + i*2, 9, 2) for i in range(8)]
assert_group('router-reactor-actions', reactor_actions)
assert all(not r.overlap(x) for r in reactor_actions for x in list_fixed), 'reactor actions overlap fixed controls'

# Router edit.
edit = [button('route', 17, 5, 48, 2)]
for prefix, x, y, w in [
    ('req', 3, 9, 36), ('fill', 44, 9, 35),
    ('me', 3, 14, 36), ('cool', 44, 14, 35),
]:
    edit += [button(prefix+'-', x, y+1, 7, 2), button(prefix+'+', x+w-7, y+1, 7, 2)]
edit += [button('done', 15, 31, 16, 2), button('delete', 35, 31, 13, 2), button('cancel', 52, 31, 16, 2)]
assert_group('router-edit', edit)

learn_actions = [button(f'learn-{i}', 67, 8 + i*2, 12, 2) for i in range(8)]
chest_actions = [button(f'chest-{i}', 67, 8 + i*2, 12, 2) for i in range(8)]
assert_group('learn-actions', learn_actions)
assert_group('chest-actions', chest_actions)

path_remove = [button(f'remove-{i}', 34, 11 + i*2, 4, 2) for i in range(7)]
path_add = [button(f'add-{i}', 75, 11 + i*2, 4, 2) for i in range(7)]
assert_group('path-remove', path_remove)
assert_group('path-add', path_add)
assert all(not a.overlap(b) for a in path_remove for b in path_add)

path_nav = [
    button('chain-prev', 5, 27, 10, 2), button('chain-next', 28, 27, 10, 2),
    button('valve-prev', 46, 27, 10, 2), button('valve-next', 69, 27, 10, 2),
    button('path-done', 15, 32, 16, 2), button('path-clear', 35, 32, 13, 2),
    button('path-cancel', 52, 32, 16, 2),
]
assert_group('path-nav', path_nav)

# Page-local buttons all finish before the global footer starts on row 38.
all_page = list_fixed + reactor_actions + edit + learn_actions + chest_actions + path_remove + path_add + path_nav
assert max(r.y2 for r in all_page) <= 34

print('fuel_scada_touch_alignment_test.py: ok')
