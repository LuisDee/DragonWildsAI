from brain.situation import MAX_LINES, summary


def digest(**values):
    return "\n".join(summary({'name':'dev', **values}))


def status(carried='complete', right='complete', left='complete'):
    return {'carried': {'status':carried, 'count_semantics':'exact' if carried=='complete' else 'lower_bound'},
            'held': {'right':{'status':right}, 'left':{'status':left}}}


def test_legacy_empty_and_malformed_are_unknown():
    for raw in (None, {}, {'carried':{'status':'complete'}}, {'carried':{'status':'bad','count_semantics':'exact'}}):
        text=digest(inventory={},inventory_read_status=raw)
        assert 'Carrying: nothing' not in text
        assert 'carried unknown; hands right unknown, left unknown' in text
        assert 'Carrying: unknown' in text


def test_partial_counts_lower_bounds_and_unmapped_unknown_quantity():
    text=digest(inventory={'wood':3},inventory_read_status=status('partial','partial','unknown'),
                inventory_items=[{'item':'wood','where':'bag','count':3},
                                 {'item':'ore','name':'Ore','where':'unmapped'}])
    assert 'wood x3 (at least)' in text and 'Ore (quantity unknown)' in text
    assert 'hands right partial, left unknown' in text


def test_unknown_additional_stack_prevents_exact_quantity():
    text=digest(inventory={'wood':3},inventory_read_status=status(),
                inventory_items=[{'item':'wood','where':'bag','count':3},{'item':'wood','where':'unmapped'}])
    assert 'wood x3 (at least; additional quantity unknown)' in text


def test_explicit_complete_empty_or_counts():
    assert 'Carrying: nothing' in digest(inventory={},inventory_read_status=status())
    assert 'Carrying: wood x3' in digest(inventory={'wood':3},inventory_read_status=status())
    assert 'at least' not in digest(inventory={'wood':3},inventory_read_status=status())


def test_positive_held_actions_and_independent_unknown_hand():
    text=digest(inventory={},inventory_read_status=status('unknown','complete','unknown'),
                held_actions={'item_name':'Stone Tool','item':'item_tool','actions':[{'name':'Swing'}]})
    assert 'holding Stone Tool' in text and 'hands right complete, left unknown' in text
    assert 'bare hands' not in text and 'Carrying: nothing' not in text


def test_unknown_food_quantity_and_read_under_budget():
    state={'inventory':{},'inventory_items':[{'item':'apple','name':'Apple','where':'bag','consumable':'food'}],
           'health':50,'max_health':100,'inventory_read_status':status('partial','unknown','unknown')}
    lines=summary(state)
    assert len(lines)<=MAX_LINES and any('carried partial' in x for x in lines)
    assert 'Apple quantity unknown' in '\n'.join(lines)
    assert 'Apple x1' not in '\n'.join(lines)


def test_complete_empty_aggregate_cannot_hide_observed_positive_stack():
    text=digest(inventory={},inventory_read_status=status(),
                inventory_items=[{'item':'wood','where':'bag','count':2}])
    assert 'Carrying: nothing' not in text and 'wood x2 (at least)' in text
    assert 'carried unknown (inconsistent observations)' in text


def test_understated_aggregate_and_duplicate_stacks_are_reconciled():
    rows=[{'item':'wood','where':'bag','count':2},{'item':'wood','where':'hotbar','count':3}]
    text=digest(inventory={'wood':3},inventory_read_status=status(),inventory_items=rows)
    assert 'wood x5 (at least)' in text
    exact=digest(inventory={'wood':5},inventory_read_status=status(),inventory_items=rows)
    assert 'wood x5' in exact and 'at least' not in exact
    legacy=digest(inventory={},inventory_items=rows)
    assert 'wood x5 (at least)' in legacy and 'Carrying: nothing' not in legacy


def test_budget_keeps_threat_job_recent_life_and_unknown_read():
    state={'inventory':{},'inventory_read_status':status('unknown','unknown','unknown'),
           'health':1,'max_health':100,'hydration':1,'hydration_max':100,
           'sustenance':1,'sustenance_max':100,'last_death':{'ago_s':80},
           'gear':{'head':'hat'},'skills':[{'skill':'Artisan','level':1}],
           'quests':{'active':[{'quest':'A','step':'B'}]},
           'held_actions':{'item_name':'Tool','actions':[{'name':'Swing'}]},
           'time_of_day':{'hour':12},'vitals_policy':{'drink_below_pct':50},
           'players':[{'name':'Friend','distance':5}],
           'nearby_entities':[{'name':'Wolf','id':'w1','distance':2,'hostile':True}],
           'nearby_items':[{'name':'Rock','item':'rock','distance':1}],
           'nearby_resources':[{'name':'Tree','kind':'tree','distance':1}],
           'interactables':[{'name':'Bed','id':'bed'}],
           'stations_nearby':[{'name':'Station','id':'station'}], 'places':['Camp']}
    lines=summary(state,active_goal='find shelter',tasks=[{'status':'pending','skill':'find'}])
    assert len(lines)<=MAX_LINES
    assert any(x.startswith('Inventory read:') for x in lines)
    assert any(x.startswith('Recent:') for x in lines)
    assert any(x.startswith('Creatures') and 'Wolf' in x for x in lines)
    assert any(x.startswith('Job:') and 'find shelter' in x for x in lines)
