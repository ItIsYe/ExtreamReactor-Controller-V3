"""Independent rectangle proof for the rewritten fixed 82x40 FUEL UI."""
from dataclasses import dataclass
W,H=82,40
@dataclass(frozen=True)
class R:
    name:str; x1:int; y1:int; x2:int; y2:int
    def inside(self): return 1<=self.x1<=self.x2<=W and 1<=self.y1<=self.y2<=H
    def overlap(self,o): return not (self.x2<o.x1 or o.x2<self.x1 or self.y2<o.y1 or o.y2<self.y1)
def b(n,x,y,w,h): return R(n,x,y,x+w-1,y+h-1)
def group(name,rs):
    for r in rs: assert r.inside(), f'{name}: outside {r}'
    for i,a in enumerate(rs):
        for c in rs[i+1:]: assert not a.overlap(c), f'{name}: overlap {a} / {c}'

footer=[b('back',3,38,13,2),b('next',67,38,13,2)]; group('footer',footer)
details=[b('prev',4,6,12,2),b('next',67,6,12,2)]; group('details',details)
overview=[b('prev',4,33,12,2),b('next',67,33,12,2)]; group('overview',overview)

list_fixed=[b('logistics',3,5,14,1),b('export',19,5,36,1),b('learn',58,5,22,1),
            b('page-prev',5,28,11,1),b('page-next',67,28,11,1),
            b('save',24,33,15,2),b('discard',44,33,15,2)]
group('list-fixed',list_fixed)
row_edit=[b(f'edit{i}',72,11+i*2,7,1) for i in range(8)]; group('list-row-edit',row_edit)
assert all(not a.overlap(c) for a in row_edit for c in list_fixed)

edit=[b('route',22,5,39,1)]
for p,x,y,w in [('req',3,9,36),('fill',44,9,35),('me',3,16,36),('cool',44,16,35)]:
    edit += [b(p+'-',x+2,y+3,6,1), b(p+'+',x+w-8,y+3,6,1)]
edit += [b('done',18,31,14,2),b('delete',35,31,13,2),b('cancel',52,31,15,2)]
group('edit',edit)

learn=[b(f'learn{i}',68,8+i*2,11,1) for i in range(8)]
chest=[b(f'chest{i}',68,8+i*2,11,1) for i in range(8)]
group('learn',learn); group('chest',chest)

path_rows=[b(f'x{i}',35,11+i*2,3,1) for i in range(7)]+[b(f'plus{i}',76,11+i*2,3,1) for i in range(7)]
group('path-row-actions',path_rows)
path_nav=[b('teach',24,5,35,1),b('cp',5,28,10,1),b('cn',28,28,10,1),b('vp',46,28,10,1),b('vn',69,28,10,1),
          b('done',18,32,14,2),b('clear',35,32,13,2),b('cancel',52,32,15,2)]
group('path-nav',path_nav)
assert all(not a.overlap(c) for a in path_rows for c in path_nav)

all_page=details+overview+list_fixed+row_edit+edit+learn+chest+path_rows+path_nav
assert max(r.y2 for r in all_page)<=34
assert all(r.y2<38 for r in all_page)
print('fuel_scada_touch_alignment_test.py: ok')
