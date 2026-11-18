"""tools/natural_interruptions.py rev b: the cases the thirst, fight and grave studies (2026-11-18) found miscounted.
Each log is built in the shape of the brain-live rows it was read from (run named in each test)."""
import json

from tools import natural_interruptions as ni

T0 = 1794900000.0


class Log:
    def __init__(self, ask, player='Tester'):
        self.rows = [{'ts': T0, 'kind': 'session_start'}]
        self.n = 0
        self.add(1.0, 'chat_decision', player=player, text=ask, decision='addressed', command=ask)

    def add(self, t, kind, **kw):
        self.rows.append(dict(ts=T0 + t, kind=kind, **kw))
        self.rows.sort(key=lambda r: r['ts'])
        return self

    def call(self, t, t_end, tool, args=None, ok=True, reason=None, **data):
        self.n += 1
        tid = f'task{self.n}'
        self.add(t, 'tool_call', task_id=tid, tool=tool, args=args or {})
        if t_end is not None:
            self.add(t_end, 'tool_result', task_id=tid, tool=tool, result={'ok': ok, 'reason': reason, 'data': data})
        return self

    def activity(self, t, kind, **kw):
        return self.add(t, 'event', event=dict(type='activity', kind=kind, ts=T0 + t, **kw))

    def end(self, t):
        return self.add(t, 'session_end')


def run(log, name='brain-live-20261118-000000-1.jsonl'):
    return ni.analyze_run(name, log.rows)


def test_quest_completed_by_the_talk_after_the_drink_is_a_resume_and_ends_the_ask():
    # brain-live-20261116-231753-18560 (B15): Dirty Water at the quest's campfire, the reflex drank during the hand-in talk
    log = Log('claude, go and see Vannaka near the windmill and do his quest')
    log.call(3, 15, 'go_to', {'target': 'Vannaka'})
    log.call(16, 19, 'talk', {'target': 'Vannaka'}, detail='The conversation ended. Ratcatcher, next step: Kill rats.')
    log.call(56, 66, 'attack', {'target': 'Giant Rat'})
    log.call(83, 123, 'craft', {'item': 'Rat Roast', 'station': 'Campfire'}, detail='I made 1 Rat Roast in the Campfire.')
    log.call(127, 138, 'craft', {'input': 'Dirty Water', 'station': 'BP_Station_Campfire_C_1', 'fuel': 'Ash Logs'},
             detail='I made 1 Clean Water in the Campfire.')
    log.call(139.5, 155.5, 'talk', {'target': 'Vannaka'},
             detail='The conversation ended. Quest Ratcatcher is complete. New quest Rune Mysteries: Speak to Zanik.')
    log.activity(141, 'reflex_use', by='reflex', ok=True, name='Clean Water')
    log.add(158, 'request_closed', request='claude, go and see Vannaka near the windmill and do his quest')
    log.end(160)
    rows = run(log)
    i1b, i1a = [r for r in rows if r['kind'] == 'I1']
    assert i1b['ask_end_why'] == 'quest_complete'
    assert i1b['outcome'] == 'resumed' and i1b['resume_s'] == 1.5  # he went back to the quest when the craft ended
    assert i1b['resume_call'].startswith('talk')
    # the reflex drink during the hand-in talk is its own (reflex-only) interruption, and the talk ran through it
    assert i1a['reflex_only'] and i1a['outcome'] == 'resumed_through'


def test_upkeep_after_the_quest_is_complete_is_not_in_the_ask():
    log = Log('claude, go and see Vannaka near the windmill and do his quest')
    log.call(3, 15, 'go_to', {'target': 'Vannaka'})
    log.call(16, 30, 'talk', {'target': 'Vannaka'}, detail='The conversation ended. Quest Ratcatcher is complete.')
    log.call(33, 34, 'consume', {'item': 'Clean Water'})
    log.end(300)
    assert run(log) == []


def test_count_reached_ends_the_ask_before_the_bite():
    # brain-live-20261116-041441-7796 (B00): "chop about 13 logs", got 17, then ate: "done, got way more than 13"
    log = Log('claude chop about 13 logs')
    log.call(5, 87, 'gather', {'resource': 'ash', 'count': 13}, gathered=17, detail='Got 17 ash.')
    log.call(90, 90.4, 'consume', {'item': 'Fillet'})
    log.end(126)
    assert run(log) == []


def test_stored_counts_end_a_chest_ask():
    # brain-live-20261118-041716-24732: "put twenty ash logs and ten stone in a chest", both stored, then he cooked
    log = Log('claude, put twenty ash logs and ten stone in a chest at your base')
    log.call(4, 13, 'gather', {'resource': 'loose_stones', 'count': 5}, gathered=5)
    log.call(17, 31, 'store', {'item': 'Ash Logs', 'container': 'Crate_1', 'count': 20}, ok=False, reason='container_full')
    log.call(33, 36, 'store', {'item': 'Ash Logs', 'container': 'Crate_2', 'count': 20})
    log.call(37, 41, 'store', {'item': 'Stone', 'container': 'Crate_2', 'count': 10})
    log.call(44, 70, 'craft', {'input': 'Raw Rat Meat', 'count': 7, 'station': 'Campfire'})
    log.end(98)
    assert run(log) == []
    assert ni.ask_items('claude, put twenty ash logs and ten stone in a chest') == [(20, 'ash'), (10, 'stone')]


def test_quest_part_handed_in_then_a_drink_is_stalled_before_not_a_miss():
    # brain-live-20261116-114618-17240 (B10): the hand-in said the quest is not over; he drank and stood to the end
    log = Log('claude, go and see Zanik and do her quest')
    log.call(10, 185, 'gather', {'resource': 'ash', 'count': 46}, gathered=46)
    log.call(186, 194, 'talk', {'target': 'Zanik'}, detail='The conversation ended. One part of Rune Mysteries is complete, '
                                                           'but Rune Mysteries is not over. It goes on as a new quest.')
    log.call(197, 198, 'consume', {'item': 'Clean Water'})
    log.end(900)
    (row,) = run(log)
    assert row['ask_end_why'] == 'run_end'  # a quest part does not end the ask
    assert row['outcome'] == 'stalled_before' and row['stalled_before'].startswith('subgoal_end')
    assert row['outcome'] in ni.NOT_JUDGED


def test_quest_part_then_more_talk_is_still_a_subgoal_end():
    # brain-live-20261116-102023-10384 (B09): talked to Zanik again ("The conversation ended.") before the water
    log = Log('claude, go and see Zanik and do her quest')
    log.call(10, 260, 'gather', {'resource': 'ash', 'count': 50}, gathered=50)
    log.call(262, 266, 'talk', {'target': 'Zanik'}, detail='One part of Rune Mysteries is complete, but Rune Mysteries is not over.')
    log.call(280, 285, 'talk', {'target': 'Zanik'}, detail='The conversation ended.')
    log.call(300, 320, 'collect_water', {'count': 4})
    log.end(440)
    (row,) = run(log)
    assert row['outcome'] == 'stalled_before' and row['stalled_before'].startswith('subgoal_end')


def test_blocked_before_the_drink_is_stalled_before():
    # brain-live-20261117-211034-9796 (B22): no copper within 90 m, explore found none, then water, then an honest park
    ask = 'claude, we need thirty copper ore in the chest at your base'
    log = Log(ask)
    log.call(5, 6, 'gather', {'resource': 'copper', 'count': 30}, ok=False, reason='nothing_in_range',
             detail="I can't find any copper within 90 m of me.")
    log.call(8, 300, 'explore', {'about': 'copper ore'}, ok=False, reason='nothing_in_range', detail='explored 8 legs')
    log.call(318, 340, 'collect_water', {'count': 3})
    log.add(476, 'request_parked', request=ask)
    log.end(480)
    (row,) = run(log)
    assert row['outcome'] == 'stalled_before' and row['stalled_before'].startswith('blocked: explore nothing_in_range')


def test_a_resume_after_a_block_still_counts_as_resumed():
    ask = 'claude, we need thirty copper ore in the chest at your base'
    log = Log(ask)
    log.call(8, 300, 'explore', {'about': 'copper ore'}, ok=False, reason='nothing_in_range')
    log.call(318, 340, 'collect_water', {'count': 3})
    log.call(345, 500, 'explore', {'about': 'copper ore vein'}, ok=False, reason='nothing_in_range')
    log.end(600)
    (row,) = run(log)
    assert row['outcome'] == 'resumed' and row['resume_s'] == 5.0
    assert row['stalled_before'].startswith('blocked')  # kept for reading, not used to judge a resume


def test_explore_running_through_reflex_fights_is_resumed_through_even_if_it_found_nothing():
    # brain-live-20261116-062404-15380 (fight row 0): three reflex fights inside explore "Air Altar"; it failed later
    log = Log('claude, go and see Zanik and do her quest')
    log.call(5, 90, 'talk', {'target': 'Zanik'}, detail='Rune Mysteries, next step: find the Air Altar.')
    log.call(95, 300, 'explore', {'about': 'Air Altar'}, ok=False, reason='nothing_in_range',
             detail="saw nothing matching 'Air Altar'")
    log.activity(103, 'combat_started', by='reflex', target='Giant Rat', why='attacking_me')
    log.activity(131, 'combat_end', by='reflex', target='Giant Rat', outcome='killed', dur_s=28)
    log.end(400)
    (row,) = [r for r in run(log) if r['kind'] == 'I2']
    assert row['outcome'] == 'resumed_through' and row['resume_s'] == 0.0


def test_a_call_cut_short_by_his_death_is_not_resumed_through():
    log = Log('claude, go and see Zanik and do her quest')
    log.call(5, 90, 'talk', {'target': 'Zanik'})
    log.call(95, 140, 'explore', {'about': 'Air Altar'}, ok=False, reason='companion_down', detail='I went down')
    log.activity(103, 'combat_started', by='reflex', target='Goblin Runt', why='hostile_near')
    log.activity(131, 'combat_end', by='reflex', target='Goblin Runt', outcome='died', dur_s=28)
    log.end(400)
    rows = run(log)
    i2 = [r for r in rows if r['kind'] == 'I2'][0]
    assert i2['outcome'] != 'resumed_through'
    assert len([r for r in rows if r['kind'] == 'I3']) == 1


def test_grave_walk_for_a_gear_up_ask_serves_it_and_runs_through_fights():
    # brain-live-20261117-182130-17296 (fight row 23): go_to my_grave resumed past two reflex fights and arrived
    log = Log('claude get all your stuff together and gear up properly')
    log.call(5, 9, 'interact', {'target': 'BP_RuntimeSpawnedWorldItem_C_1'})
    log.call(110, 262, 'go_to', {'target': 'my_grave:1794886979.896'})
    log.activity(205, 'combat_started', by='reflex', target='Goblin Runt', why='hostile_near')
    log.activity(218, 'combat_end', by='reflex', target='Goblin Runt', outcome='killed', dur_s=13)
    log.end(275)
    (row,) = [r for r in run(log) if r['kind'] == 'I2']
    assert row['outcome'] == 'resumed_through' and row['resume_call'].startswith('go_to')


def test_grave_call_is_upkeep_only_after_a_death_in_the_ask():
    call = {'tool': 'go_to', 'args': {'target': 'my_grave:1794960568.869'}, 'detail': '', 'said': ''}
    ask = 'claude, we need thirty copper ore in the chest at your base'
    assert ni.classify(call, ask, died_before=True) == 'death'
    assert ni.classify(call, ask, died_before=False) is None


def test_one_take_all_is_credited_to_one_death():
    # brain-live-20261118-010135-17424 (d10, d11): died on the explore, died again on the grave walk (bare hands,
    # nothing lost), then reached the d10 grave and took all
    log = Log('claude, we need thirty copper ore in the chest at your base')
    log.call(10, 100.5, 'explore', {'about': 'copper ore vein'}, ok=False, reason='companion_down', detail='I went down')
    log.activity(100, 'combat_end', by='reflex', target='Goblin Warrior', outcome='died', dur_s=14)
    log.call(110, 201, 'go_to', {'target': f'my_grave:{T0 + 100:.3f}'}, ok=False, reason='interrupted',
             detail='the move ended without arriving (stopped)')
    log.activity(200, 'combat_end', by='reflex', target='Giant Rat', outcome='died', dur_s=70)
    log.call(260, 400, 'go_to', {'target': f'my_grave:{T0 + 100:.3f}'})
    log.call(401, 402, 'interact', {'target': 'BP_PlayerGravestone_C_2147450795'}, detail='Picked up 7 Animal Hide Scraps')
    log.call(410, 411, 'gather', {'resource': 'copper', 'count': 30}, ok=False, reason='nothing_in_range')
    log.end(500)
    i3 = sorted((r for r in run(log) if r['kind'] == 'I3'), key=lambda r: r['start_s'])
    assert len(i3) == 2
    assert i3[0]['grave_recovered_s'] == 302.0
    assert i3[1]['grave_recovered_s'] is None


def test_serving_call_between_upkeep_splits_the_interruption():
    # brain-live-20261117-140049-22000: water at the campfire, back to the quest, the quest done, then more water
    log = Log('claude, go and see Zanik and do her quest')
    log.call(5, 290, 'gather', {'resource': 'rune_essence', 'count': 20}, gathered=20)
    log.call(300, 326, 'craft', {'input': 'Dirty Water', 'station': 'Campfire', 'fuel': 'Ash Logs'})
    log.call(330, 348, 'go_to', {'target': 'Air Anima Vent'})
    log.call(382, 388, 'talk', {'target': 'Zanik'}, detail='The conversation ended. Quest Rune Mysteries is complete.')
    log.call(391, 410, 'collect_water', {'count': 3})
    log.end(500)
    (row,) = run(log)
    assert row['outcome'] == 'resumed' and row['end_s'] == 326.0


def _write(tmp_path, name, log):
    p = tmp_path / name
    p.write_text('\n'.join(json.dumps(r) for r in log.rows) + '\n', encoding='utf-8')


def test_since_keeps_only_asks_after_it_and_the_table_adds_up(tmp_path, capsys):
    early = Log('claude chop about 13 logs')
    early.call(5, 50, 'gather', {'resource': 'ash', 'count': 13}, gathered=5)
    early.call(55, 56, 'consume', {'item': 'Fillet'})
    early.call(60, 100, 'gather', {'resource': 'ash', 'count': 8}, gathered=8)
    early.end(200)
    late = Log('claude mine about 10 stone')
    late.rows = [dict(r, ts=r['ts'] + 7200) for r in late.rows]
    late_t = 7200
    late.call(late_t + 5, late_t + 50, 'gather', {'resource': 'stone', 'count': 10}, gathered=4)
    late.call(late_t + 55, late_t + 56, 'consume', {'item': 'Clean Water'})
    late.end(late_t + 400)
    _write(tmp_path, 'brain-live-20261117-100000-1.jsonl', early)
    _write(tmp_path, 'brain-live-20261117-120000-2.jsonl', late)
    since = ni.iso(T0 + 3600)
    all_rows = ni.analyze(str(tmp_path), root=str(tmp_path))
    late_rows = ni.analyze(str(tmp_path), since=since, root=str(tmp_path))
    assert [r['outcome'] for r in all_rows] == ['resumed', 'no_resume_before_run_end']
    assert len(late_rows) == 1 and late_rows[0]['run'].endswith('-2.jsonl')
    assert ni.parse_since('2026-11-17T19:50Z') == ni.parse_since('2026-11-17T19:50:00+00:00')
    ni.main(['--logs', str(tmp_path), '--root', str(tmp_path), '--since', since])
    out = capsys.readouterr().out
    assert 'rows 1 (asks since' in out
    for line in out.splitlines():
        if line.startswith('| I'):
            cells = [c.strip() for c in line.strip('|').split('|')]
            n, induced, done, stalled, short, judged = (int(c) for c in cells[1:7])
            resumed = int(cells[7].split()[0])
            not_resumed = int(cells[8].split()[0])
            assert n == induced + done + stalled + short + judged
            assert judged == resumed + not_resumed
