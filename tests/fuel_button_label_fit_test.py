"""Ensure fixed control labels fit the filled mux.button width (inner width = w-2)."""
controls = [
    ('footer-back','<< ZURUECK',13), ('footer-next','WEITER >>',13),
    ('overview-prev','<< REAKTOR',12), ('overview-next','REAKTOR >>',12),
    ('details-prev','<< REAKTOR',12), ('details-next','REAKTOR >>',12),
    ('logistics-on','LOGISTIK AN',14), ('logistics-off','LOGISTIK AUS',14),
    ('learn','+ REAKTOR',22), ('edit','EDIT',7),
    ('page-prev','<< SEITE',11), ('page-next','SEITE >>',11),
    ('save','SPEICHERN *',15), ('discard','VERWERFEN',15),
    ('step--5%','-5%',6), ('step-+5%','+5%',6), ('step--5s','-5s',6), ('step-+5s','+5s',6),
    ('done','FERTIG',14), ('delete','LOESCHEN',13), ('cancel','ABBRECHEN',15),
    ('learn-row','EINLERNEN',11), ('choose','WAEHLEN',11),
    ('chain-prev','<< KETTE',10), ('chain-next','KETTE >>',10),
    ('list-prev','<< LISTE',10), ('list-next','LISTE >>',10),
    ('remove','X',3), ('add','+',3),
]
for name,label,w in controls:
    assert len(label) <= w-2, f'{name}: label {label!r} ({len(label)}) does not fit inner width {w-2}'
print('fuel_button_label_fit_test.py: ok')
