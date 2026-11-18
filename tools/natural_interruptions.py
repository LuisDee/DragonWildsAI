"""Natural interruptions during an open player ask, from brain-live logs. Read only.

Kinds: I1 thirst/food (the reflex ate or drank, or he stopped to eat, drink or fetch water), I2 a fight the ask did not
call for, I3 his death, I4 a full bag. Each interruption that hit him while a player's ask was open, after he had acted on
it, is scored: did he take the ask up again?

Rules (rev b, 2026-11-18, after the thirst, fight and grave studies; docs/research/2026-11-18-natural-interruptions.md):
- A call serves the ask unless it is upkeep (eat, drink, water, cooking food the ask did not call for, the grave after a
  death, an unasked fight), a gear swap, or a walk or fuel gather (ash, logs, sticks) whose next call, under 90 s after
  it began, is upkeep.
- Upkeep signals closer than the kind's gap form one interruption, unless a serving call began between them (he went
  back to the ask, so what follows is a new interruption).
- An ask ends at the next ask, at request_closed / request_parked / request_done_claimed for it, at a talk result that
  says "Quest X is complete" (for a quest ask), or when his gather results reach the count the ask named (an ask with no
  delivery in it: "chop about 13 logs"). An interruption after that is not in the ask.
- A quest part handed in ("One part of X is complete, but X is not over") does not end the ask.
- Upkeep that only the reflex did (it ate or drank while a call ran) does not hold the ask: the interruption's end for
  resuming is the end of the last upkeep call he chose himself.
- A serving call in flight across the interruption's end counts as resumed at 0 s when it ended ok or ran on 10 s or more
  past it (an explore through reflex fights that later found nothing, or met a later fight), unless he died within
  those 10 s.
- A grave call is upkeep after a death in the ask. With no death in the ask (a gear-up ask after an earlier death) it
  serves the ask.
- Not resumed, but the ask had stalled before the interruption: the last serving call before it handed in a quest part
  (subgoal_end), or failed for good (blocked: no copper in reach, a talk that did not open), or he had stood 120 s or
  more (idle). Such a row is 'stalled_before' and is not judged.
- A grave's Take All is credited to one death only: the one whose time is the grave's id (go_to 'my_grave:<epoch>'),
  else the earliest death before it that has none.
- --since ISO keeps asks made at or after that time (the open-ask turn: 2026-11-17T19:50Z).

Usage: python -m tools.natural_interruptions --logs C:\\gameserver\\logs --out rows.json [--since 2026-11-17T19:50Z]
"""
import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import statistics

ACTION = {'gather', 'go_to', 'craft', 'build', 'explore', 'store', 'interact', 'attack', 'talk', 'give', 'take', 'fetch',
          'fish', 'equip', 'unequip', 'move_item', 'deconstruct', 'drop', 'cast', 'consume', 'collect_water',
          'recover_grave', 'follow', 'come_to', 'agility_course', 'tend', 'shoot', 'teleport', 'use_action', 'split',
          'build_blueprint', 'set_vitals_policy'}
WATER = re.compile(r'water', re.I)
FOOD = re.compile(r'roast|soup|cook|meat|fillet|berr|fish|stew|pie|bread|mushroom|vegetable|egg', re.I)
FOOD_ASK = re.compile(r'cook|roast|food|meat|\beat\b|ratcatcher|vannaka|soup|berr', re.I)
DORIC = re.compile(r'doric|wise old man', re.I)
FUEL = re.compile(r'ash|log|stick|wood|branch|fuel', re.I)
FUEL_ASK = re.compile(r'ash|log|stick|wood|chop', re.I)
QUEST_ASK = re.compile(r'quest|do (whatever|what) (he|she|they) asks?', re.I)
MULTI_QUEST = re.compile(r'\bquests\b|\ball\b', re.I)
QUEST_DONE = re.compile(r'Quest ([A-Z][\w\' ]{1,40}?) is complete')
PART_DONE = re.compile(r'is not over')
DELIVERY = re.compile(r'chest|bring|give|store|deliver|\bput\b|\bto me\b|\bbase\b|hand', re.I)
NUM_WORDS = {'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
             'eleven': 11, 'twelve': 12, 'fifteen': 15, 'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50}
TRANSIENT = {'interrupted', 'busy', 'still_running', 'companion_down', 'body_restarted', 'station_busy'}
IDLE_S = 120
THRU_RUN_ON_S = 10
GAPS = {'I1': 90, 'I2': 30, 'I3': 30, 'I4': 60}
OPEN_ASK_TURN = '2026-11-17T19:50Z'
FIRST_DAY = '20261116'  # older logs come from other eval shapes (go-to asks, 'drink something'); the rules fit 16 Nov on
INDUCED = {'brain-live-20261118-025304-22352.jsonl': 'I2 (goblin spawned by harness)',
           'brain-live-20261118-030932-26668.jsonl': 'I5 (brain restart)',
           'brain-live-20261118-031109-27792.jsonl': 'I5 (brain restart)'}
NOT_JUDGED = ('ask_done', 'stalled_before', 'run_ended_within_30s')


def fight_asked(ask, target):
    """True when the ask itself calls for fighting this target (Vannaka's quest is Ratcatcher: rats)."""
    t = (target or '').lower()
    if re.search(r'vannaka|ratcatcher|\brats?\b', ask, re.I) and 'rat' in t:
        return True
    if re.search(r'goblin', ask, re.I) and 'goblin' in t:
        return True
    return bool(re.search(r'\b(kill|fight|attack|hunt|slay)\b', ask, re.I)) and not re.search(r'goblin|rat', ask, re.I)


def argstr(a):
    return json.dumps(a or {})


def ask_count(text):
    """The count an ask names ('about 13 logs', 'thirty copper'), or None."""
    m = re.search(r'\b(\d{1,4})\b', text)
    if m:
        return int(m.group(1))
    for w, n in NUM_WORDS.items():
        if re.search(r'\b' + w + r'\b', text, re.I):
            return n
    return None


def ask_items(text):
    """(count, first item word) pairs an ask names: 'twenty ash logs and ten stone' -> [(20, 'ash'), (10, 'stone')]."""
    num = r'\d{1,4}|' + '|'.join(NUM_WORDS)
    out = []
    for m in re.finditer(r'\b(' + num + r')\s+(?:more\s+)?([a-z]+)', text, re.I):
        n = m.group(1).lower()
        out.append((int(n) if n.isdigit() else NUM_WORDS[n], m.group(2).lower()))
    return out


def is_grave(call):
    return call['tool'] == 'recover_grave' or (call['tool'] in ('go_to', 'interact')
                                               and re.search(r'grave', argstr(call['args']), re.I))


def classify(call, ask, died_before=False):
    """'vitals' / 'death' / 'fight' (upkeep), 'neutral', or None (serves the ask).
    died_before: he died after the ask was made and before this call (grave calls are upkeep only then)."""
    t, a = call['tool'], call.get('args') or {}
    s = argstr(a)
    det, said = call.get('detail') or '', call.get('said') or ''
    doric = DORIC.search(ask)
    food_said = re.search(r'water|drink|thirst|eat|food|hungry|berr', said, re.I)
    if t in ('interact', 'gather', 'go_to') and re.search(r'redberr|berries', det, re.I) and not FOOD_ASK.search(ask):
        return 'vitals'
    grave_said = t == 'go_to' and re.search(r'grave', said, re.I) and not re.search(
        r'copper|essence|vannaka|zanik|quest', said, re.I)
    if is_grave(call) or grave_said:
        if died_before:
            return 'death'
        if food_said and not FOOD_ASK.search(ask):
            return 'vitals'  # to the grave for the food in it
        if is_grave(call):
            return None  # no death in this ask: getting his gear back serves it (a gear-up ask)
    target = a.get('target') if isinstance(a, dict) else None
    named_elsewhere = isinstance(target, str) and not re.search(
        r'water|well|pond|lake|campfire|fire|berr|bush|food|stove|grave|^\[|^\d', target, re.I)
    if t == 'go_to' and food_said and not doric and not named_elsewhere \
            and not re.search(r'then (I.ll )?(head|go|get|mine|gather|chop)', said, re.I):
        return 'vitals'
    if t == 'collect_water' and doric:
        return None  # Getting Started: 'Collect some dirty water ... bring it back to Doric' is the ask itself
    if t in ('consume', 'collect_water', 'set_vitals_policy'):
        return 'vitals'
    if t == 'explore' and WATER.search(s) and not doric:
        return 'vitals'  # looking for water to drink
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


def ets(r):
    e = r.get('event') or {}
    return e.get('ts') or r['ts']


def load(f):
    rows = []
    for line in open(f, encoding='utf-8', errors='replace'):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and 'ts' in r and 'kind' in r:
            rows.append(r)
    return rows


def parse_since(s):
    """ISO time ('2026-11-17T19:50Z', '2026-11-17T19:50:00+00:00') -> epoch seconds."""
    if s is None:
        return None
    s = s.strip().replace('Z', '+00:00')
    t = dt.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.timestamp()


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _asks(rows, tend):
    asks = []
    for r in rows:
        if r['kind'] == 'chat_decision' and r.get('decision') == 'addressed' and r.get('player') \
                and r.get('player') != 'Claude':
            asks.append({'ts': r['ts'], 'player': r['player'], 'text': r.get('text') or r.get('command') or '',
                         'end': tend, 'end_why': 'run_end', 'end_detail': None})
    return asks


def _calls(rows):
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
            d = rr.get('data') if isinstance(rr.get('data'), dict) else {}
            calls.append({'ts': r['ts'], 'tool': r['tool'], 'args': r.get('args'), 'ep': r.get('episode_id'),
                          'end': res['ts'] if res else None, 'ok': rr.get('ok') if res else None,
                          'reason': rr.get('reason') if res else None, 'detail': str(d.get('detail', '')),
                          'gathered': d.get('gathered')})
    says = [(r['ts'], r.get('text') or '') for r in rows if r['kind'] == 'say']
    for c in calls:  # the line he said just before (or held with) the call
        near = [t for t in says if c['ts'] - 15 <= t[0] <= c['ts'] + 3]
        c['said'] = near[-1][1] if near else ''
    return calls, says


def _end_asks(asks, rows, calls):
    """Each ask ends at the first of: the next ask, its close/park/done claim, a quest completion, the count reached."""
    for i, a in enumerate(asks):
        if i + 1 < len(asks):
            a['end'], a['end_why'] = asks[i + 1]['ts'], 'new_ask'
        for r in rows:
            if not (a['ts'] < r['ts'] < a['end']):
                continue
            if r['kind'] in ('request_closed', 'request_parked', 'request_done_claimed') \
                    and (r.get('request') or '') == a['text']:
                a['end'], a['end_why'] = r['ts'], r['kind']
                break
        if QUEST_ASK.search(a['text']) and not MULTI_QUEST.search(a['text']):
            for c in calls:
                if c['tool'] == 'talk' and c['ok'] and c['end'] and a['ts'] < c['end'] < a['end']:
                    m = QUEST_DONE.search(c['detail'])
                    if m:
                        a['end'], a['end_why'], a['end_detail'] = c['end'], 'quest_complete', m.group(0)
                        break
        pairs = ask_items(a['text'])
        if pairs and DELIVERY.search(a['text']) and re.search(r'chest|crate|box|\bput\b|\bstore\b', a['text'], re.I):
            stored = collections.Counter()
            for c in calls:
                if c['tool'] == 'store' and c['ok'] and c['end'] and a['ts'] < c['end'] < a['end']:
                    it = str((c['args'] or {}).get('item') or '').lower()
                    for n, key in pairs:
                        if key in it:
                            stored[key] += int((c['args'] or {}).get('count') or 1)
                    if all(stored[key] >= n for n, key in pairs):
                        a['end'], a['end_why'] = c['end'], 'count_reached'
                        a['end_detail'] = 'stored ' + ', '.join(f'{stored[k]} of {n} {k}' for n, k in pairs)
                        break
        n = ask_count(a['text'])
        if n and not DELIVERY.search(a['text']):
            got = 0
            for c in calls:
                if c['tool'] == 'gather' and c['end'] and a['ts'] < c['end'] < a['end'] \
                        and isinstance(c.get('gathered'), (int, float)):
                    got += c['gathered']
                    if got >= n:
                        a['end'], a['end_why'] = c['end'], 'count_reached'
                        a['end_detail'] = f'gathered {got} of {n} asked'
                        break


def _signals(rows, asks, calls, deaths_by_ask):
    sig = {'I1': [], 'I2': [], 'I3': [], 'I4': []}
    ask_at = lambda t: next((a for a in asks if a['ts'] <= t < a['end']), None)
    for r in rows:
        e = r.get('event') if r['kind'] == 'event' else None
        if isinstance(e, dict) and e.get('type') == 'activity':
            k = e.get('kind')
            if k == 'reflex_use' and e.get('ok') is not False:
                sig['I1'].append({'s': ets(r), 'e': ets(r), 'src': 'reflex_use ' + str(e.get('name')), 'reflex': True})
            a_ev = ask_at(ets(r))
            asked_fight = fight_asked(a_ev['text'], str(e.get('target') or e.get('target_id'))) if a_ev else False
            if k == 'combat_started' and e.get('by') == 'reflex' and not asked_fight:
                sig['I2'].append({'s': ets(r), 'e': ets(r), 'src': f"reflex fight {e.get('target')} ({e.get('why')})"})
            if k == 'combat_end' and e.get('by') == 'reflex' and not asked_fight:
                sig['I2'].append({'s': ets(r) - float(e.get('dur_s') or 0), 'e': ets(r),
                                  'src': f"reflex fight end {e.get('target')} {e.get('outcome')} ({e.get('dur_s')} s)",
                                  'outcome': e.get('outcome')})
        if r['kind'] == 'tool_result':
            res = r.get('result') or {}
            d = res.get('data') or {}
            if res.get('reason') == 'inventory_full' or (isinstance(d, dict) and d.get('why') == 'inventory_full'):
                detail = str(d.get('detail', '')) if isinstance(d, dict) else ''
                if 'hotbar' not in detail:
                    sig['I4'].append({'s': r['ts'], 'e': r['ts'], 'src': f"{r.get('tool')} inventory_full"})
    sig['I3'] = [dict(x) for x in deaths_by_ask['_all']]
    for c in calls:
        a_for = ask_at(c['ts'])
        k = classify(c, a_for['text'] if a_for else '', died_before(c['ts'], a_for, deaths_by_ask))
        if k == 'vitals' and c['tool'] != 'set_vitals_policy':
            sig['I1'].append({'s': c['ts'], 'e': c['end'] or c['ts'], 'src': f"{c['tool']} {argstr(c['args'])[:60]}"})
        if k == 'fight':
            sig['I2'].append({'s': c['ts'], 'e': c['end'] or c['ts'], 'src': f"attack {argstr(c['args'])[:60]}"})
    return sig


def _deaths(rows, calls):
    out = []
    for r in rows:
        e = r.get('event') if r['kind'] == 'event' else None
        if isinstance(e, dict) and e.get('type') == 'activity' and e.get('kind') == 'combat_end' \
                and e.get('outcome') == 'died':
            out.append({'s': ets(r), 'e': ets(r), 'src': f"died to {e.get('target')} ({e.get('by')})"})
    for c in calls:
        if c['reason'] == 'companion_down':
            out.append({'s': c['end'] or c['ts'], 'e': c['end'] or c['ts'], 'src': f"{c['tool']} companion_down"})
    return sorted(out, key=lambda x: x['s'])


def died_before(t, ask, deaths_by_ask):
    if not ask:
        return False
    return any(ask['ts'] <= d['s'] < t for d in deaths_by_ask['_all'])


def _cluster(ss, gap, serving_starts=()):
    """Signals closer than gap form one interruption, unless he went back to the ask (a serving call began) between."""
    ss = sorted(ss, key=lambda x: x['s'])
    clusters = []
    for s in ss:
        if clusters and s['s'] - clusters[-1]['e'] <= gap \
                and not any(clusters[-1]['e'] < t < s['s'] for t in serving_starts):
            c = clusters[-1]
            c['e'] = max(c['e'], s['e'])
            c['src'].append(s['src'])
            c['reflex_only'] = c['reflex_only'] and bool(s.get('reflex'))
            if not s.get('reflex'):
                c['e_model'] = max(c['e_model'] or s['e'], s['e'])
            if s.get('outcome'):
                c['outcome'] = s['outcome']
        else:
            clusters.append({'s': s['s'], 'e': s['e'], 'src': [s['src']], 'outcome': s.get('outcome'),
                             'reflex_only': bool(s.get('reflex')), 'e_model': None if s.get('reflex') else s['e']})
    return clusters


def _grave_credit(rows_i3, calls, ask_of, deaths_by_ask):
    """Credit each grave's Take All to one death: the one whose epoch is the grave's id, else the earliest without one."""
    recov = []
    last_grave_id = None
    for x in calls:
        if x['tool'] == 'go_to' and is_grave(x):
            m = re.search(r'my_grave:(\d+(?:\.\d+)?)', argstr(x['args']))
            if m:
                last_grave_id = float(m.group(1))
        if x['tool'] in ('interact', 'recover_grave') and is_grave(x) and x['ok']:
            recov.append((x, last_grave_id))
    claimed = {}
    for x, gid in recov:
        cands = [o for o in rows_i3 if o['_s'] < x['ts'] and o['_ask'] is ask_of(x['ts']) and id(o) not in claimed]
        if not cands:
            continue
        pick = None
        if gid is not None:
            pick = next((o for o in cands if abs(o['_s'] - gid) < 5), None)
        pick = pick or cands[0]
        claimed[id(pick)] = x
        pick['grave_recovered_s'] = round(x['end'] - pick['_s'], 1)


def analyze_run(name, rows, brain_done=None, ledger=None, induced=None):
    """All scored interruption rows of one brain-live log."""
    if not rows:
        return []
    t0, tend = rows[0]['ts'], rows[-1]['ts']
    asks = _asks(rows, tend)
    if not asks:
        return []
    calls, says = _calls(rows)
    _end_asks(asks, rows, calls)
    player_lines = [r['ts'] for r in rows if r['kind'] == 'event' and (r.get('event') or {}).get('type') == 'chat_heard'
                    and (r['event'].get('player') or '') != 'Claude']
    ask_of = lambda t: next((a for a in asks if a['ts'] <= t < a['end']), None)
    deaths_by_ask = {'_all': _deaths(rows, calls)}
    cls = lambda x, a: classify(x, a['text'], died_before(x['ts'], a, deaths_by_ask))
    sig = _signals(rows, asks, calls, deaths_by_ask)
    memo = {}

    def serves(x, a):
        """A call that serves the ask: not upkeep, and not a gather or walk for the upkeep step right after it."""
        k = (id(x), id(a))
        if k not in memo:
            ok = cls(x, a) is None
            fuel = x['tool'] == 'gather' and FUEL.search(argstr(x['args'])) and not FUEL_ASK.search(a['text'])
            if ok and (x['tool'] == 'go_to' or fuel):
                later = [y for y in calls if y['ts'] > x['ts'] and cls(y, a) != 'neutral']
                if later and later[0]['ts'] - x['ts'] < 90 and cls(later[0], a) in ('vitals', 'death'):
                    ok = False  # fuel/sticks or a walk for the upkeep step that follows
            memo[k] = ok
        return memo[k]

    serving_starts = [x['ts'] for x in calls if ask_of(x['ts']) and serves(x, ask_of(x['ts']))]
    out, i3 = [], []
    for kind, ss in sig.items():
        for c in _cluster(ss, GAPS[kind], serving_starts):
            a = ask_of(c['s'])
            if not a:
                continue
            served_before = [x for x in calls if a['ts'] <= x['ts'] < c['s'] and serves(x, a)]
            if not served_before:
                continue
            start, end = c['s'], c['e']
            # reflex-only upkeep (it ate or drank while a call ran) does not hold the ask
            end_eff = (c['e_model'] if c['e_model'] is not None else start) if kind == 'I1' else end
            row = {'kind': kind, 'run': name, 'induced': (induced or {}).get(name), 'ask': a['text'],
                   'ask_player': a['player'], 'ask_iso': iso(a['ts']), 'ask_s': round(a['ts'] - t0, 1),
                   'ask_end_s': round(a['end'] - t0, 1), 'ask_end_why': a['end_why'], 'ask_end_detail': a['end_detail'],
                   'start_s': round(start - t0, 1), 'end_s': round(end - t0, 1),
                   'resume_from_s': round(end_eff - t0, 1), 'signals': c['src'][:8],
                   'ledger_runs': sorted((ledger or {}).get('brain2run', {}).get(name, [])),
                   'run_done': (brain_done or {}).get(name)}
            if ledger:
                row['ledger'] = [{k: l.get(k) for k in ('run', 'class', 'first_wrong', 'void')}
                                 for rn in row['ledger_runs'] for l in ledger.get('by_run', {}).get(rn, [])]
            if kind == 'I1':
                row['reflex_only'] = c['reflex_only']
            if kind == 'I2':
                row['fight_outcome'] = c.get('outcome')
            if kind == 'I3':
                row['grave_recovered_s'] = None
                row['grave_tried'] = any(cls(x, a) == 'death' for x in calls if start < x['ts'] < a['end'])
                row['_s'], row['_ask'] = start, a
                i3.append(row)
            thru = None
            if kind in ('I1', 'I2'):
                for x in calls:
                    if x['ts'] < end_eff and x['end'] and x['end'] >= end_eff and serves(x, a) \
                            and (x['ok'] or x['end'] - end_eff >= THRU_RUN_ON_S) \
                            and not any(end_eff <= d['s'] <= end_eff + THRU_RUN_ON_S for d in deaths_by_ask['_all']):
                        thru = x
                        break
            nxt = []
            for x in calls:
                if x['ts'] <= end_eff or x['ts'] >= a['end']:
                    continue
                if not serves(x, a):
                    continue
                nxt.append(x)
                break
            newline = next((t for t in player_lines if end_eff < t < a['end']), None)
            row['stalled_before'] = _stalled(calls, a, start, serves)
            if thru:
                row.update(outcome='resumed_through', resume_s=0.0,
                           resume_call=f"{thru['tool']} {argstr(thru['args'])[:80]} (in flight across it, "
                                       f"{'ok' if thru['ok'] else thru['reason']} {round(thru['end'] - end_eff, 1)} s after)")
            elif nxt and (newline is None or nxt[0]['ts'] < newline):
                x = nxt[0]
                row.update(outcome='resumed', resume_s=round(x['ts'] - end_eff, 1), resume_at_s=round(x['ts'] - t0, 1),
                           resume_call=f"{x['tool']} {argstr(x['args'])[:80]}", resume_ok=x['ok'],
                           resume_reason=x['reason'])
            else:
                if a['end_why'] in ('quest_complete', 'count_reached', 'request_done_claimed'):
                    o = 'ask_done'
                elif row['stalled_before']:
                    o = 'stalled_before'
                elif newline is not None:
                    o = 'new_player_line'
                elif a['end_why'] in ('request_parked', 'request_closed'):
                    o = a['end_why'].replace('request_', '')
                elif (brain_done or {}).get(name) and a['end_why'] == 'run_end':
                    o = 'ask_done'
                elif a['end_why'] == 'run_end' and a['end'] - end < 30:
                    o = 'run_ended_within_30s'
                else:
                    o = 'no_resume_before_' + a['end_why']
                row.update(outcome=o, resume_s=None,
                           said_after=[s[:120] for t, s in says if end < t < a['end']][:3],
                           asked_question=any('?' in s for t, s in says if end < t < a['end']))
            out.append(row)
    _grave_credit(i3, calls, ask_of, deaths_by_ask)
    for r in i3:
        r.pop('_s', None)
        r.pop('_ask', None)
    return sorted(out, key=lambda r: (r['start_s'], r['kind']))


def _stalled(calls, a, start, serves):
    """Why the ask had already stopped before the interruption, or None: subgoal_end / blocked / idle."""
    if any(x['ts'] < start and (x['end'] is None or x['end'] > start) and serves(x, a) for x in calls):
        return None  # a serving call was running when it hit
    done = [x for x in calls if a['ts'] <= x['ts'] and x['end'] and x['end'] <= start and serves(x, a)]
    if not done:
        return None
    done.sort(key=lambda x: x['end'])
    last = done[-1]
    for x in reversed(done):  # a quest part handed in, then only more talk with the same NPC
        if x['tool'] != 'talk':
            break
        if x['ok'] and PART_DONE.search(x['detail']):
            return f"subgoal_end: {x['detail'][:100]}"
    if last['ok'] is False and last['reason'] not in TRANSIENT:
        return f"blocked: {last['tool']} {last['reason']}: {last['detail'][:100]}"
    if start - last['end'] >= IDLE_S:
        return f"idle: {round(start - last['end'])} s since {last['tool']} ended"
    return None


def load_ledger(root):
    """failure ledger rows by run, and the eval runs each brain log belongs to (optional context)."""
    by_run, brain2run, brain_done = collections.defaultdict(list), collections.defaultdict(set), {}
    p = os.path.join(root, 'docs', 'failure_ledger.jsonl')
    if os.path.exists(p):
        for l in open(p, encoding='utf-8'):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            by_run[r.get('run')].append(r)
    for f in glob.glob(os.path.join(root, 'logs', 'evals', '*.jsonl')):
        for l in open(f, encoding='utf-8', errors='replace'):
            try:
                r = json.loads(l)
            except ValueError:
                continue
            if not isinstance(r, dict) or not r.get('run'):
                continue
            for b in ([r['brain_log']] if r.get('brain_log') else []) + list(r.get('brain_logs') or []):
                brain2run[b].add(r['run'])
                if 'done' in r:
                    brain_done[b] = brain_done.get(b, False) or bool(r.get('done'))
    return {'by_run': by_run, 'brain2run': brain2run}, brain_done


def analyze(logs_dir, since=None, root=None, pattern='brain-live-*.jsonl', first_day=FIRST_DAY):
    root = root or os.path.dirname(os.path.abspath(logs_dir))
    ledger, brain_done = load_ledger(root)
    since_ts = parse_since(since)
    out = []
    for f in sorted(glob.glob(os.path.join(logs_dir, pattern))):
        m = re.search(r'(\d{8})-\d{6}', os.path.basename(f))
        if first_day and m and m.group(1) < first_day:
            continue
        rows = load(f)
        if not rows or (since_ts is not None and rows[-1]['ts'] < since_ts):
            continue
        name = os.path.basename(f)
        for r in analyze_run(name, rows, brain_done, ledger, INDUCED):
            out.append(r)
    if since_ts is not None:
        out = [r for r in out if parse_since(r['ask_iso']) >= since_ts]
    return out


def table(rows):
    """Per-kind counts that add up: rows = induced + not judged + judged; judged = resumed + not resumed."""
    lines = ['| kind | rows | induced | ask done | stalled before | run ended <30 s | judged | resumed (0 s through) '
             '| not resumed (park / close / other) | median s to resume (excl. through) | p75 |',
             '|---|---|---|---|---|---|---|---|---|---|---|']
    subs = [('I1a reflex only', 'I1', True), ('I1b he stopped', 'I1', False), ('I2 fight', 'I2', None),
            ('I3 death', 'I3', None), ('I4 full bag', 'I4', None)]
    for label, kind, sub in subs:
        rs = [o for o in rows if o['kind'] == kind and (sub is None or o.get('reflex_only') == sub)]
        nat = [o for o in rs if not o['induced']]
        jud = [o for o in nat if o['outcome'] not in NOT_JUDGED]
        res = [o for o in jud if o['outcome'].startswith('resumed')]
        thr = [o for o in res if o['outcome'] == 'resumed_through']
        no = [o for o in jud if not o['outcome'].startswith('resumed')]
        lat = sorted(o['resume_s'] for o in res if o['outcome'] == 'resumed')
        med = round(statistics.median(lat), 1) if lat else '-'
        p75 = round(lat[min(len(lat) - 1, int(0.75 * len(lat)))], 1) if lat else '-'
        lines.append(f"| {label} | {len(rs)} | {len(rs) - len(nat)} | {sum(o['outcome'] == 'ask_done' for o in nat)} "
                     f"| {sum(o['outcome'] == 'stalled_before' for o in nat)} "
                     f"| {sum(o['outcome'] == 'run_ended_within_30s' for o in nat)} | {len(jud)} "
                     f"| {len(res)} ({len(thr)}) | {len(no)} ({sum(o['outcome'] == 'parked' for o in no)} / "
                     f"{sum(o['outcome'] == 'closed' for o in no)} / "
                     f"{sum(o['outcome'] not in ('parked', 'closed') for o in no)}) | {med} | {p75} |")
    i3 = [o for o in rows if o['kind'] == 'I3' and not o['induced']]
    lines.append(f"\nI3: deaths {len(i3)} in {len({o['run'] for o in i3})} runs; grave tried after "
                 f"{sum(bool(o.get('grave_tried')) for o in i3)}; graves opened {sum(o.get('grave_recovered_s') is not None for o in i3)}"
                 f"; I2 fights ending in his death {sum(o.get('fight_outcome') == 'died' for o in rows if o['kind'] == 'I2' and not o['induced'])}")
    return '\n'.join(lines)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--logs', default=r'C:\gameserver\logs', help='folder with brain-live-*.jsonl')
    p.add_argument('--root', default=None, help='repo root for the failure ledger and eval rows (default: logs/..)')
    p.add_argument('--since', default=None, help=f'keep asks made at or after this ISO time (open-ask turn: {OPEN_ASK_TURN})')
    p.add_argument('--glob', default='brain-live-*.jsonl')
    p.add_argument('--first-day', default=FIRST_DAY, help="skip logs named before this day (YYYYMMDD; '' for all)")
    p.add_argument('--out', default=None, help='write the rows here (json)')
    a = p.parse_args(argv)
    rows = analyze(a.logs, a.since, a.root, a.glob, a.first_day)
    if a.out:
        with open(a.out, 'w', encoding='utf-8') as f:
            json.dump(rows, f, indent=1)
    print(f"rows {len(rows)}" + (f" (asks since {a.since})" if a.since else ''))
    print(table(rows))
    return rows


if __name__ == '__main__':
    main()
