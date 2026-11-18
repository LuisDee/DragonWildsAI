"""Natural interruptions during an open player ask, from brain-live logs. Read only."""
import json, glob, os, re, sys, statistics, collections
ROOT = r'C:\gameserver'
OUT = sys.argv[1]
ACTION = {'gather','go_to','craft','build','explore','store','interact','attack','talk','give','take','fetch','fish',
          'equip','unequip','move_item','deconstruct','drop','cast','consume','collect_water','recover_grave','follow',
          'come_to','agility_course','tend','shoot','teleport','use_action','split','build_blueprint','set_vitals_policy'}
WATER = re.compile(r'water', re.I)
FOOD = re.compile(r'roast|soup|cook|meat|fillet|berr|fish|stew|pie|bread|mushroom|vegetable|egg', re.I)
FOOD_ASK = re.compile(r'cook|roast|food|meat|\beat\b|ratcatcher|vannaka|soup|berr', re.I)


def fight_asked(ask, target):
    """True when the ask itself calls for fighting this target (Vannaka's quest is Ratcatcher: rats)."""
    t = (target or '').lower()
    if re.search(r'vannaka|ratcatcher|\brats?\b', ask, re.I) and 'rat' in t:
        return True
    if re.search(r'goblin', ask, re.I) and 'goblin' in t:
        return True
    return bool(re.search(r'\b(kill|fight|attack|hunt|slay)\b', ask, re.I)) and not re.search(r'goblin|rat', ask, re.I)
INDUCED = {'brain-live-20261118-025304-22352.jsonl': 'I2 (goblin spawned by harness)',
           'brain-live-20261118-030932-26668.jsonl': 'I5 (brain restart)',
           'brain-live-20261118-031109-27792.jsonl': 'I5 (brain restart)'}


def argstr(a):
    return json.dumps(a or {})


def classify(call, ask):
    """'vitals' / 'death' / 'fight' (upkeep), 'neutral', or None (serves the ask)."""
    t, a = call['tool'], call.get('args') or {}
    s = argstr(a)
    det, said = call.get('detail') or '', call.get('said') or ''
    doric = re.search(r'doric|wise old man', ask, re.I)
    if t in ('interact', 'gather', 'go_to') and re.search(r'redberr|berries', det, re.I) and not FOOD_ASK.search(ask):
        return 'vitals'
    if t == 'go_to' and re.search(r'grave', said, re.I) and not re.search(r'copper|essence|vannaka|zanik|quest', said, re.I):
        return 'death'
    if t == 'go_to' and re.search(r'water|drink|thirst|eat|food|hungry|berr', said, re.I) and not doric             and not re.search(r'then (I.ll )?(head|go|get|mine|gather|chop)', said, re.I):
        return 'vitals'
    if t == 'collect_water' and re.search(r'doric|wise old man', ask, re.I):
        return None  # Getting Started: 'Collect some dirty water ... bring it back to Doric' is the ask itself
    if t in ('consume', 'collect_water', 'set_vitals_policy'):
        return 'vitals'
    if t == 'explore' and WATER.search(s) and not re.search(r'doric|wise old man', ask, re.I):
        return 'vitals'  # looking for water to drink
    if t == 'recover_grave' or (t in ('go_to', 'interact') and re.search(r'grave', s, re.I)):
        return 'death'
    if t == 'craft' and WATER.search(s):
        return 'vitals'
    if t == 'craft' and FOOD.search(s) and not FOOD_ASK.search(ask):
        return 'vitals'
    if t == 'gather' and (WATER.search(s) or re.search(r'berr|mushroom', s, re.I)) and not FOOD_ASK.search(ask):
        return 'vitals'
    if t == 'attack' and not fight_asked(ask, s):
        return 'fight'
    if t in ('equip', 'unequip', 'move_item', 'drop', 'split'):
        return 'neutral'
    return None


led = [json.loads(l) for l in open(os.path.join(ROOT, 'docs/failure_ledger.jsonl'), encoding='utf-8')]
by_run = collections.defaultdict(list)
for r in led:
    by_run[r['run']].append(r)
brain2run = collections.defaultdict(set)
brain_done = {}
for f in glob.glob(os.path.join(ROOT, 'logs/evals/*.jsonl')):
    for l in open(f, encoding='utf-8', errors='replace'):
        try:
            r = json.loads(l)
        except Exception:
            continue
        if not isinstance(r, dict) or not r.get('run'):
            continue
        for b in ([r['brain_log']] if r.get('brain_log') else []) + list(r.get('brain_logs') or []):
            brain2run[b].add(r['run'])
            if 'done' in r:
                brain_done[b] = brain_done.get(b, False) or bool(r.get('done'))


def load(f):
    rows = []
    for line in open(f, encoding='utf-8', errors='replace'):
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
    return rows


def ets(r):
    e = r.get('event') or {}
    return e.get('ts') or r['ts']


occ = []
files = sorted(glob.glob(os.path.join(ROOT, 'logs/brain-live-2026111[678]-*.jsonl')))
for f in files:
    name = os.path.basename(f)
    rows = load(f)
    if not rows:
        continue
    t0, tend = rows[0]['ts'], rows[-1]['ts']
    asks = []
    for r in rows:
        if r['kind'] == 'chat_decision' and r.get('decision') == 'addressed' and r.get('player') and r.get('player') != 'Claude':
            asks.append({'ts': r['ts'], 'player': r['player'], 'text': r.get('text') or r.get('command') or '',
                         'end': tend, 'end_why': 'run_end'})
    if not asks:
        continue
    player_lines = [r['ts'] for r in rows if r['kind'] == 'event' and (r.get('event') or {}).get('type') == 'chat_heard'
                    and (r['event'].get('player') or '') != 'Claude']
    for i, a in enumerate(asks):
        if i + 1 < len(asks):
            a['end'], a['end_why'] = asks[i + 1]['ts'], 'new_ask'
        for r in rows:
            if a['ts'] < r['ts'] < a['end'] and r['kind'] in ('request_closed', 'request_parked', 'request_done_claimed') \
                    and (r.get('request') or '') == a['text']:
                a['end'], a['end_why'] = r['ts'], r['kind']
                break
    results = {}
    for r in rows:
        if r['kind'] == 'tool_result':
            k = r.get('task_id') or r.get('call')
            if k:
                results[k] = r
    calls = []
    for r in rows:
        if r['kind'] == 'tool_call' and r.get('tool') in ACTION:
            res = results.get(r.get('task_id') or r.get('call'))
            rr = (res.get('result') or {}) if res else {}
            calls.append({'ts': r['ts'], 'tool': r['tool'], 'args': r.get('args'), 'ep': r.get('episode_id'),
                          'end': res['ts'] if res else None, 'ok': rr.get('ok') if res else None,
                          'reason': rr.get('reason') if res else None,
                          'detail': str((rr.get('data') or {}).get('detail', '')) if isinstance(rr.get('data'), dict) else ''})
    says = [(r['ts'], r.get('text') or '') for r in rows if r['kind'] == 'say']
    for c in calls:  # the line he said just before (or held with) the call
        near = [t for t in says if c['ts'] - 15 <= t[0] <= c['ts'] + 3]
        c['said'] = near[-1][1] if near else ''
    sig = {'I1': [], 'I2': [], 'I3': [], 'I4': []}
    for r in rows:
        e = r.get('event') if r['kind'] == 'event' else None
        if isinstance(e, dict) and e.get('type') == 'activity':
            k = e.get('kind')
            if k == 'reflex_use' and e.get('ok') is not False:
                sig['I1'].append({'s': ets(r), 'e': ets(r), 'src': 'reflex_use ' + str(e.get('name')), 'reflex': True})
            a_ev = next((a for a in asks if a['ts'] <= ets(r) < a['end']), None)
            asked_fight = fight_asked(a_ev['text'], str(e.get('target') or e.get('target_id'))) if a_ev else False
            if k == 'combat_started' and e.get('by') == 'reflex' and not asked_fight:
                sig['I2'].append({'s': ets(r), 'e': ets(r), 'src': f"reflex fight {e.get('target')} ({e.get('why')})"})
            if k == 'combat_end' and e.get('by') == 'reflex' and not asked_fight:
                sig['I2'].append({'s': ets(r) - float(e.get('dur_s') or 0), 'e': ets(r),
                                  'src': f"reflex fight end {e.get('target')} {e.get('outcome')} ({e.get('dur_s')} s)",
                                  'outcome': e.get('outcome')})
            if k == 'combat_end' and e.get('outcome') == 'died':
                sig['I3'].append({'s': ets(r), 'e': ets(r), 'src': f"died to {e.get('target')} ({e.get('by')})"})
        if r['kind'] == 'tool_result':
            res = r.get('result') or {}
            d = res.get('data') or {}
            if res.get('reason') == 'inventory_full' or (isinstance(d, dict) and d.get('why') == 'inventory_full'):
                detail = str(d.get('detail', '')) if isinstance(d, dict) else ''
                if 'hotbar' not in detail:
                    sig['I4'].append({'s': r['ts'], 'e': r['ts'], 'src': f"{r.get('tool')} inventory_full"})
    for c in calls:
        a_for = next((a for a in asks if a['ts'] <= c['ts'] < a['end']), None)
        k = classify(c, a_for['text'] if a_for else '')
        if k == 'vitals' and c['tool'] != 'set_vitals_policy':
            sig['I1'].append({'s': c['ts'], 'e': c['end'] or c['ts'], 'src': f"{c['tool']} {argstr(c['args'])[:60]}"})
        if k == 'fight':
            sig['I2'].append({'s': c['ts'], 'e': c['end'] or c['ts'], 'src': f"attack {argstr(c['args'])[:60]}"})
        if c['reason'] == 'companion_down':
            sig['I3'].append({'s': c['end'] or c['ts'], 'e': c['end'] or c['ts'], 'src': f"{c['tool']} companion_down"})
    gaps = {'I1': 90, 'I2': 30, 'I3': 30, 'I4': 60}
    for kind, ss in sig.items():
        ss.sort(key=lambda x: x['s'])
        clusters = []
        for s in ss:
            if clusters and s['s'] - clusters[-1]['e'] <= gaps[kind]:
                c = clusters[-1]
                c['e'] = max(c['e'], s['e'])
                c['src'].append(s['src'])
                c['reflex_only'] = c['reflex_only'] and bool(s.get('reflex'))
                if s.get('outcome'):
                    c['outcome'] = s['outcome']
            else:
                clusters.append({'s': s['s'], 'e': s['e'], 'src': [s['src']], 'outcome': s.get('outcome'),
                                 'reflex_only': bool(s.get('reflex'))})
        for c in clusters:
            a = next((a for a in asks if a['ts'] <= c['s'] < a['end']), None)
            if not a:
                continue
            served_before = [x for x in calls if a['ts'] <= x['ts'] < c['s'] and classify(x, a['text']) is None]
            if not served_before:
                continue
            start, end = c['s'], c['e']
            row = {'kind': kind, 'run': name, 'induced': INDUCED.get(name), 'ask': a['text'], 'ask_player': a['player'],
                   'ask_s': round(a['ts'] - t0, 1), 'ask_end_s': round(a['end'] - t0, 1), 'ask_end_why': a['end_why'],
                   'start_s': round(start - t0, 1), 'end_s': round(end - t0, 1), 'signals': c['src'][:8],
                   'ledger_runs': sorted(brain2run.get(name, [])), 'run_done': brain_done.get(name),
                   'ledger': [{k: l.get(k) for k in ('run', 'class', 'first_wrong', 'void')} for rn in sorted(brain2run.get(name, [])) for l in by_run.get(rn, [])]}
            if kind == 'I1':
                row['reflex_only'] = c['reflex_only']
            if kind == 'I2':
                row['fight_outcome'] = c.get('outcome')
            if kind == 'I3':
                g = next((x for x in calls if start < x['ts'] < a['end'] and classify(x, a['text']) == 'death'
                          and x['tool'] in ('interact', 'recover_grave') and x['ok']), None)
                row['grave_recovered_s'] = round(g['end'] - start, 1) if g else None
                row['grave_tried'] = any(classify(x, a['text']) == 'death' for x in calls if start < x['ts'] < a['end'])
            thru = next((x for x in calls if x['ts'] < start and x['end'] and x['end'] >= end
                         and classify(x, a['text']) is None and x['ok']), None) if kind in ('I1', 'I2') else None
            nxt = []
            for x in calls:
                if x['ts'] <= end or x['ts'] >= a['end']:
                    continue
                if classify(x, a['text']) is not None:
                    continue
                later = [y for y in calls if y['ts'] > x['ts'] and classify(y, a['text']) != 'neutral']
                if x['tool'] in ('gather', 'go_to') and later and later[0]['ts'] - x['ts'] < 90 \
                        and classify(later[0], a['text']) in ('vitals', 'death'):
                    continue  # fuel/sticks or a walk for the upkeep step that follows
                nxt.append(x)
                break
            newline = next((t for t in player_lines if end < t < a['end']), None)
            if thru:
                row.update(outcome='resumed_through', resume_s=0.0,
                           resume_call=f"{thru['tool']} {argstr(thru['args'])[:80]} (in flight across it, ok)")
            elif nxt and (newline is None or nxt[0]['ts'] < newline):
                x = nxt[0]
                row.update(outcome='resumed', resume_s=round(x['ts'] - end, 1), resume_at_s=round(x['ts'] - t0, 1),
                           resume_call=f"{x['tool']} {argstr(x['args'])[:80]}", resume_ok=x['ok'],
                           resume_reason=x['reason'])
            else:
                if newline is not None:
                    o = 'new_player_line'
                elif a['end_why'] in ('request_parked', 'request_closed'):
                    o = a['end_why'].replace('request_', '')
                elif brain_done.get(name) and a['end_why'] in ('run_end', 'request_closed'):
                    o = 'ask_done_no_resume_needed'
                elif a['end_why'] == 'run_end' and a['end'] - end < 30:
                    o = 'run_ended_within_30s'
                else:
                    o = 'no_resume_before_' + a['end_why']
                row.update(outcome=o, resume_s=None,
                           said_after=[s[:120] for t, s in says if end < t < a['end']][:3],
                           asked_question=any('?' in s for t, s in says if end < t < a['end']))
            occ.append(row)

json.dump(occ, open(OUT, 'w', encoding='utf-8'), indent=1)
nat = [o for o in occ if not o['induced']]
print('total', len(occ), 'natural', len(nat))
for kind in ('I1', 'I2', 'I3', 'I4'):
    for sub in ((None,) if kind != 'I1' else (True, False)):
        rs = [o for o in nat if o['kind'] == kind and (sub is None or o.get('reflex_only') == sub)]
        res = [o for o in rs if o['outcome'].startswith('resumed')]
        lat = [o['resume_s'] for o in res]
        lat2 = [o['resume_s'] for o in rs if o['outcome'] == 'resumed']
        print(kind, sub, 'n', len(rs), 'runs', len({o['run'] for o in rs}), 'resumed', len(res),
              'through', sum(o['outcome'] == 'resumed_through' for o in rs),
              'median', statistics.median(lat) if lat else None, 'median_excl_through', statistics.median(lat2) if lat2 else None,
              dict(collections.Counter(o['outcome'] for o in rs)))
    if kind == 'I2':
        print('  fights ending died', sum(o.get('fight_outcome') == 'died' for o in nat if o['kind'] == 'I2'))
    if kind == 'I3':
        rs = [o for o in nat if o['kind'] == 'I3']
        print('  grave recovered', sum(o.get('grave_recovered_s') is not None for o in rs),
              'tried', sum(bool(o.get('grave_tried')) for o in rs))
