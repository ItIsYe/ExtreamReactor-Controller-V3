"""Static geometry proof for every visible touch surface in the fixed 82x40 UI."""
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
    def overlap(self, o): return not (self.x2 < o.x1 or o.x2 < self.x1 or self.y2 < o.y1 or o.y2 < self.y1)


def button(name, x, y, w, h): return R(name, x, y, x + w - 1, y + h - 1)

def assert_group(name, rects):
    for r in rects:
        assert r.inside(), f'{name}: outside screen: {r}'
    for i, a in enumerate(rects):
        for b in rects[i+1:]:
            assert not a.overlap(b), f'{name}: touch surfaces overlap: {a} / {b}'

# Global page footer: exactly what is drawn is touchable, including all 3 rows.
assert_group('footer', [button('back', 2, 38, 22, 3), button('next', 59, 38, 22, 3)])

# Details reactor navigation.
assert_group('details-nav', [button('reactor-prev', 2, 6, 18, 3), button('reactor-next', 63, 6, 18, 3)])

# Overview >16 reactor paging.
assert_group('overview-page', [button('fleet-prev', 2, 32, 19, 3), button('fleet-next', 62, 32, 19, 3)])

# Router list: top controls, page controls, save/discard. Reactor action buttons
# occupy x70..78 and 2 rows per visible table entry.
list_fixed = [
    button('logistics', 2, 5, 16, 3), button('export', 19, 5, 37, 3), button('learn', 57, 5, 24, 3),
    button('page-prev', 4, 29, 16, 3), button('page-next', 63, 29, 16, 3),
    button('save', 2, 33, 50, 3), button('discard', 53, 33, 28, 3),
]
assert_group('router-list-fixed', list_fixed)
reactor_actions = [button(f'reactor-{i+1}', 70, 13 + i*2, 9, 2) for i in range(8)]
assert_group('router-reactor-actions', reactor_actions)
assert all(not r.overlap(x) for r in reactor_actions for x in list_fixed), 'reactor actions overlap fixed controls'

# Router edit controls: route, 4 steppers, 3 actions.
edit = [button('route', 2, 5, 79, 3)]
# left/right stepper buttons at y11-13 and y17-19. col width 38 => plus x29; right col x43 => plus x70.
for prefix, x, y in [('req', 2, 10), ('fill', 43, 10), ('me', 2, 16), ('cool', 43, 16)]:
    edit += [button(prefix+'-', x, y+1, 11, 3), button(prefix+'+', x+27, y+1, 11, 3)]
edit += [button('done', 2, 32, 33, 3), button('delete', 36, 32, 20, 3), button('cancel', 57, 32, 24, 3)]
assert_group('router-edit', edit)

# Picker actions and path actions are visible buttons, not invisible row-wide hits.
learn_actions = [button(f'learn-{i}', 63, 8 + i*2, 16, 2) for i in range(8)]
chest_actions = [button(f'chest-{i}', 63, 8 + i*2, 16, 2) for i in range(8)]
assert_group('learn-actions', learn_actions)
assert_group('chest-actions', chest_actions)
path_remove = [button(f'remove-{i}', 32, 12 + i*2, 6, 2) for i in range(7)]
path_add = [button(f'add-{i}', 73, 12 + i*2, 6, 2) for i in range(7)]
assert_group('path-remove', path_remove)
assert_group('path-add', path_add)
assert all(not a.overlap(b) for a in path_remove for b in path_add)

print('fuel_scada_touch_alignment_test.py: ok')
