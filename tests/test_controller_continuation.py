"""Deferred direct-chat slices run through the real Agent and Controller with a fake model."""
import json

from brain.budget import Budget
from brain.interface import CommandReceived
from brain.llm import FakeLLM, ToolCall


def action(i):
    return FakeLLM.say('', ToolCall('go_to', {'target': 'lake' if i % 2 else 'camp'}, f'id-{i}'))


def live_identity(rig):
    read = rig.game.get_state
    def state():
        result = read()
        result['data'].update(name='ClaudeDev', pawn='pawn-1')
        return result
    rig.game.get_state = state


def start(rig, count=6):
    rig.controller_llm.push(*(action(i) for i in range(count)), FakeLLM.say(''))
    rig.game.player_say('visit both places in order')
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5
    assert rig.agent._continuation is not None


def test_deferred_real_agent_keeps_results_and_never_replays(rig):
    start(rig)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 6
    assert rig.agent._continuation is None
    messages = rig.controller_llm.calls[5]['messages']
    result = next(m for m in reversed(messages) if m.get('role') == 'tool')
    assert result['tool_call_id'] == 'id-4'
    assert json.loads(result['content'])['ok'] is True
    n = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == n


def test_new_command_takes_precedence(rig):
    start(rig)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say('', FakeLLM.call('stop')))
    rig.game.player_say('stop')
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5
    assert len(rig.calls('stop')) == 1
    assert rig.agent._continuation is None


def test_known_reader_failure_refuses_deferred_request(rig):
    live_identity(rig)
    start(rig)
    def bad():
        raise RuntimeError('unavailable')
    rig.agent.budget = Budget(bad, cap_usd=10)
    rig.agent.continuation_budget_required = True
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert len(rig.calls('go_to')) == 5
    assert any('thinking budget' in line for line in rig.companion_said())


def test_deadline_refuses_deferred_request(rig):
    start(rig)
    rig.agent.clock = lambda: rig.agent._continuation['deadline'] + 1
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert any('time limit' in line for line in rig.companion_said())


def test_ceiling_ends_after_one_extra_slice(rig):
    start(rig, count=11)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 9
    assert rig.agent._continuation is None
    assert any('available time and attention' in line for line in rig.companion_said())


def test_nested_read_denial_cannot_fall_back_to_another_call(rig):
    live_identity(rig)
    start(rig)
    rig.controller_llm.script.clear()
    rig.controller.max_calls = 2
    rig.controller_llm.push(FakeLLM.say('', FakeLLM.call('look', about='lake')),
                            FakeLLM.say('', FakeLLM.call('look', about='lake')),
                            FakeLLM.say('', FakeLLM.call('go_to', target='lake')))
    class Limit:
        spend_fn = lambda: 0
        def has_successful_read(self): return True
        def __init__(self): self.checks = 0
        def allows(self, kind):
            self.checks += 1
            return self.checks <= 4
    rig.agent.budget = Limit()
    rig.agent.continuation_budget_required = True
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before + 2
    assert len(rig.calls('go_to')) == 5
    assert any('thinking budget' in line for line in rig.companion_said())


def test_nested_talk_check_denial_does_not_say_unverified_claim(rig):
    live_identity(rig)
    start(rig)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say("I'll do the next thing."), FakeLLM.say('', FakeLLM.call('go_to', target='lake')))
    class Limit:
        spend_fn = lambda: 0
        def has_successful_read(self): return True
        def __init__(self): self.checks = 0
        def allows(self, kind):
            self.checks += 1
            return self.checks <= 2
    rig.agent.budget = Limit()
    rig.agent.continuation_budget_required = True
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before + 1
    assert len(rig.calls('go_to')) == 5
    assert not any("I'll do the next thing" in line for line in rig.companion_said())
    assert any('thinking budget' in line for line in rig.companion_said())


def test_world_change_invalidates_pending(rig, monkeypatch):
    monkeypatch.setenv('DW_WORLD_GUID', 'first')
    start(rig)
    monkeypatch.setenv('DW_WORLD_GUID', 'second')
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert len(rig.calls('go_to')) == 5
    assert rig.agent._continuation is None



def test_first_spend_read_in_flight_is_not_ready():
    from threading import Event, Thread
    started, release = Event(), Event()
    def reader():
        started.set()
        assert release.wait(5)
        return 1.0
    budget = Budget(reader, cap_usd=10, background=True)
    worker = Thread(target=budget._read)
    worker.start()
    try:
        assert started.wait(5)
        assert budget._at is not None
        assert not budget.has_successful_read()
    finally:
        release.set()
        worker.join(5)
    assert not worker.is_alive()
    assert budget.has_successful_read()



def test_liveagent_ignored_ambient_chat_does_not_discard(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact'})
    for _ in range(6):
        r.body.act('interact', ok(target=INFUSION))
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['ambient'] = FakeLLM.say('')
    r.model.turns = [FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(5)] + [FakeLLM.say('')]
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    assert len(r.body.calls) == 5 and r.agent._continuation is not None
    r.body.emit({'type': 'chat_heard', 'player': 'Other', 'text': 'ambient'})
    r.at(1).step()
    assert len(r.body.calls) == 5 and r.agent._continuation is not None
    r.at(4).step()
    assert len(r.body.calls) == 6 and r.agent._continuation is None


def test_paused_or_unavailable_state_stops_before_continuation(rig):
    from brain.interface import fail
    start(rig)
    rig.game.get_state = lambda: fail('companion_down', detail='client paused')
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert len(rig.calls('go_to')) == 5
    assert rig.agent._continuation is None


def test_body_safety_event_is_handled_before_deferred_actions(rig):
    from brain.interface import Attacked
    start(rig)
    rig.agent.body_self_defends = True
    rig.game._events.append(Attacked(by='wolf', name='Wolf'))
    rig.agent.step()
    rows = rig.log.read_all()
    safety = next(i for i, row in enumerate(rows) if row['kind'] == 'attacked_body_reflex')
    sixth = [i for i, row in enumerate(rows) if row['kind'] == 'tool_call' and row.get('tool') == 'go_to'][5]
    assert safety < sixth


def test_repeated_tool_names_keep_distinct_result_ids(rig):
    rig.controller_llm.push(*(action(i) for i in range(4)),
        FakeLLM.say('', ToolCall('go_to', {'target': 'lake'}, 'one'), ToolCall('go_to', {'target': 'camp'}, 'two')),
        FakeLLM.say(''))
    rig.game.player_say('visit both places in order')
    rig.agent.step()
    assert len(rig.calls('go_to')) == 6
    rig.agent.step()
    msgs = rig.controller_llm.calls[-1]['messages']
    results = [m for m in msgs if m.get('role') == 'tool' and m.get('tool_call_id') in ('one', 'two')]
    assert {m['tool_call_id'] for m in results} == {'one', 'two'}
    actual = {m['tool_call_id']: json.loads(m['content'])['data']['target_position'] for m in results}
    assert actual == {'one': [40.0, 30.0, 0.0], 'two': [0.0, 0.0, 0.0]}


def test_model_can_end_with_standing_action(rig):
    start(rig)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say('', FakeLLM.call('follow', player='Luis')))
    rig.agent.step()
    assert len(rig.calls('follow')) == 1
    assert rig.agent._continuation is None


def test_model_can_choose_goal_in_continuation(rig):
    start(rig)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(FakeLLM.say('', FakeLLM.call('start_goal', goal='visit the lake')))
    rig.planner_llm.push(FakeLLM.plan([], ask_help='Need help.'))
    rig.agent.step()
    assert rig.agent._continuation is None
    assert len(rig.planner_llm.calls) == 1
    assert rig.store.progress_path.read_text(encoding='utf8').count('goal started') == 1


def test_paused_board_invalidates_deferred_work(rig):
    from types import SimpleNamespace
    start(rig)
    rig.agent.director = SimpleNamespace(running=False, ops=SimpleNamespace(b=SimpleNamespace(paused={'reason': 'paused'})),
                                         tick=lambda: None)
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert rig.agent._continuation is None


def test_live_missing_character_identity_fails_closed(rig):
    start(rig)
    rig.agent.continuation_budget_required = True
    before = len(rig.controller_llm.calls)
    rig.agent.step()
    assert len(rig.controller_llm.calls) == before
    assert rig.agent._continuation is None


def test_death_during_provider_response_prevents_old_action(rig):
    flags = {'dead': False}
    read = rig.game.get_state
    def state():
        out = read()
        out['data']['dead'] = flags['dead']
        return out
    rig.game.get_state = state
    start(rig)
    rig.controller_llm.script.clear()
    def die(messages, tools):
        flags['dead'] = True
        return action(5)
    rig.controller_llm.push(die)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5
    assert any('state changed or is unavailable' in line for line in rig.companion_said())


def test_budget_denial_after_provider_response_prevents_old_action(rig):
    live_identity(rig)
    start(rig)
    class Limit:
        spend_fn = lambda: 0
        def __init__(self): self.blocked = False
        def has_successful_read(self): return True
        def allows(self, kind): return not self.blocked
    limit = Limit()
    rig.agent.budget = limit
    rig.agent.continuation_budget_required = True
    rig.controller_llm.script.clear()
    def deny(messages, tools):
        limit.blocked = True
        return action(5)
    rig.controller_llm.push(deny)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5
    assert any('thinking budget' in line for line in rig.companion_said())


def test_reentrant_addressed_command_invalidates_response_without_competing_voice(rig):
    start(rig)
    rig.controller_llm.script.clear()
    def replacement(messages, tools):
        rig.game.player_say('stop')
        rig.agent.pump()
        return action(5)
    rig.controller_llm.push(replacement, FakeLLM.say('', FakeLLM.call('stop')))
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5
    assert len(rig.calls('stop')) == 1
    assert not any('earlier request' in line for line in rig.companion_said())


def test_safety_arriving_during_provider_is_processed_before_action(rig):
    from brain.interface import Attacked
    start(rig)
    rig.agent.body_self_defends = True
    rig.controller_llm.script.clear()
    def attacked(messages, tools):
        rig.game._events.append(Attacked(by='wolf', name='Wolf'))
        return action(5)
    rig.controller_llm.push(attacked, FakeLLM.say(''))
    rig.agent.step()
    rows = rig.log.read_all()
    safety = next(i for i, row in enumerate(rows) if row['kind'] == 'attacked_body_reflex')
    sixth = [i for i, row in enumerate(rows) if row['kind'] == 'tool_call' and row.get('tool') == 'go_to'][5]
    assert safety < sixth


def test_paused_during_provider_response_prevents_action(rig):
    flags = {'paused': False}
    read = rig.game.get_state
    def state():
        out = read()
        out['data']['paused'] = flags['paused']
        return out
    rig.game.get_state = state
    start(rig)
    rig.controller_llm.script.clear()
    def pause(messages, tools):
        flags['paused'] = True
        return action(5)
    rig.controller_llm.push(pause)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5


def test_changed_world_during_provider_response_prevents_action(rig, monkeypatch):
    monkeypatch.setenv('DW_WORLD_GUID', 'first')
    start(rig)
    rig.controller_llm.script.clear()
    def change(messages, tools):
        monkeypatch.setenv('DW_WORLD_GUID', 'second')
        return action(5)
    rig.controller_llm.push(change)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 5


def test_failed_last_action_gets_one_specific_failure_line(rig):
    start(rig, count=8)
    rig.controller_llm.script.clear()
    rig.controller_llm.push(action(5), action(6), action(7))
    def fail_last(messages, tools):
        rig.game.script_failure('go_to', 'nothing_in_range')
        return action(8)
    rig.controller_llm.push(fail_last)
    rig.agent.step()
    assert len(rig.calls('go_to')) == 9
    said = rig.companion_said()
    assert len(said) == 1
    assert not any('available time and attention' in line for line in said)


def test_ambient_arriving_during_response_defers_selected_action_once(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact'})
    for _ in range(6):
        r.body.act('interact', ok(target=INFUSION))
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['ambient'] = FakeLLM.say('')
    r.model.turns = [FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(5)] + [FakeLLM.say('')]
    complete = r.model.complete
    def inject(messages, tools=None):
        response = complete(messages, tools)
        if len(r.model.calls) == 6:
            r.body.emit({'type': 'chat_heard', 'player': 'Other', 'text': 'ambient'})
        return response
    r.model.complete = inject
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    assert len(r.body.calls) == 5
    r.at(1).step()
    assert len(r.body.calls) == 5
    assert len(r.model.calls) == 6
    assert r.agent._continuation.get('dispatch_decision') is not None
    r.at(2).step()
    assert len(r.body.calls) == 5 and len(r.model.calls) == 6
    r.at(4).step()
    assert len(r.body.calls) == 6
    assert r.agent._continuation is None
    # One call to ignore ambient, then one normal response after the selected action; no replay of the decision.
    assert len(r.model.calls) == 8
    r.at(5).step()
    assert len(r.body.calls) == 6 and len(r.model.calls) == 8


def test_addressed_chat_arriving_during_response_owns_voice_and_cancels_action(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact'})
    for _ in range(5):
        r.body.act('interact', ok(target=INFUSION))
    r.body.act('stop', ok())
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['stop'] = FakeLLM.say('Stopping.', FakeLLM.call('stop'))
    r.model.turns = [FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(5)]
    complete = r.model.complete
    def inject(messages, tools=None):
        response = complete(messages, tools)
        if len(r.model.calls) == 6:
            r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude stop'})
        return response
    r.model.complete = inject
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    r.at(1).step()
    assert [tool for tool, _ in r.body.calls] == ['interact'] * 5 + ['stop']
    assert not any('earlier request' in line for line in r.body.said)
    assert r.agent._continuation is None


def test_ambient_during_nested_read_keeps_consumed_results_and_selected_action(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact', 'look'})
    for _ in range(6):
        r.body.act('interact', ok(target=INFUSION))
    r.body.look_things = []
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['ambient'] = FakeLLM.say('')
    r.model.turns = ([FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(4)] +
                     [FakeLLM.say('', ToolCall('look', {'about': 'lake'}, 'read-id')),
                      FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)), FakeLLM.say('')])
    complete = r.model.complete
    def inject(messages, tools=None):
        response = complete(messages, tools)
        if len(r.model.calls) == 6:
            r.body.emit({'type': 'chat_heard', 'player': 'Other', 'text': 'ambient'})
        return response
    r.model.complete = inject
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    r.at(1).step()
    assert [name for name, _ in r.body.calls].count('interact') == 5
    assert sum(row.get('tool') == 'look' for row in r.records('tool_call')) == 1
    assert len(r.model.calls) == 7
    r.at(4).step()
    assert [name for name, _ in r.body.calls].count('interact') == 6
    assert sum(row.get('tool') == 'look' for row in r.records('tool_call')) == 1
    assert len(r.model.calls) == 9


def test_ambient_between_selected_actions_preserves_partial_turn(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact', 'go_to'})
    for _ in range(5):
        r.body.act('interact', ok(target=INFUSION))
    r.body.act('interact', ok(target=INFUSION), emitted=[{'type': 'chat_heard', 'player': 'Other', 'text': 'ambient'}])
    r.body.act('go_to', ok(position=[1, 2, 3], target_position=[1, 2, 3]))
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['ambient'] = FakeLLM.say('')
    r.model.turns = ([FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(4)] +
                     [FakeLLM.say('Doing it.', ToolCall('interact', {'target': INFUSION}, 'first-id'),
                                  ToolCall('go_to', {'target': [1, 2, 3]}, 'second-id')), FakeLLM.say('')])
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    r.at(1).step()
    assert [name for name, _ in r.body.calls] == ['interact'] * 6
    assert len(r.model.calls) == 6
    assert r.agent._continuation['partial_turn']['index'] == 1
    r.at(2).step()
    assert len(r.model.calls) == 6
    r.at(4).step()
    assert [name for name, _ in r.body.calls] == ['interact'] * 6 + ['go_to']
    assert len(r.model.calls) == 8
    messages = r.model.calls[-1]['messages']
    results = {m['tool_call_id']: json.loads(m['content']) for m in messages
               if m.get('role') == 'tool' and m.get('tool_call_id') in {'first-id', 'second-id'}}
    assert results['first-id']['data']['target'] == INFUSION
    assert results['second-id']['data']['target_position'] == [1, 2, 3]
    assert r.body.said.count('Doing it.') == 1
    r.at(5).step()
    assert len(r.body.calls) == 7 and len(r.model.calls) == 8


def test_addressed_between_selected_actions_cancels_remainder(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact', 'go_to'})
    for _ in range(5):
        r.body.act('interact', ok(target=INFUSION))
    r.body.act('interact', ok(target=INFUSION), emitted=[{'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude stop'}])
    r.body.act('stop', ok())
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['stop'] = FakeLLM.say('Stopping.', FakeLLM.call('stop'))
    r.model.turns = ([FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(4)] +
                     [FakeLLM.say('Doing it.', ToolCall('interact', {'target': INFUSION}, 'first-id'),
                                  ToolCall('go_to', {'target': [1, 2, 3]}, 'second-id'))])
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    r.at(1).step()
    assert [name for name, _ in r.body.calls] == ['interact'] * 6 + ['stop']
    assert r.body.said.count('Doing it.') <= 1
    assert r.body.said[-1] == 'Stopping.'
    assert not any('earlier request' in line for line in r.body.said)
    assert r.agent._continuation is None


def test_ambient_after_final_action_keeps_results_for_next_model_turn(tmp_path):
    from test_event_hygiene import Replay, STATES, INFUSION
    from brain.interface import ok
    r = Replay(tmp_path, STATES[5], tools={'get_state', 'say', 'stop', 'interact', 'go_to'})
    for _ in range(5):
        r.body.act('interact', ok(target=INFUSION))
    r.body.act('interact', ok(target='done-first'), emitted=[{'type': 'chat_heard', 'player': 'Other', 'text': 'ambient'}])
    r.body.act('go_to', ok(position=[1, 2, 3]))
    r.model.replies['work'] = FakeLLM.say('', FakeLLM.call('interact', target=INFUSION))
    r.model.replies['ambient'] = FakeLLM.say('')
    r.model.turns = ([FakeLLM.say('', FakeLLM.call('interact', target=INFUSION)) for _ in range(4)] +
                     [FakeLLM.say('', ToolCall('interact', {'target': INFUSION}, 'completed-id')),
                      FakeLLM.say('', ToolCall('go_to', {'target': [1, 2, 3]}, 'next-id')), FakeLLM.say('')])
    r.body.emit({'type': 'chat_heard', 'player': 'Zezima', 'text': 'claude work'})
    r.at(0).step()
    r.at(1).step()
    assert [name for name, _ in r.body.calls] == ['interact'] * 6
    assert len(r.model.calls) == 6
    r.at(4).step()
    assert [name for name, _ in r.body.calls] == ['interact'] * 6 + ['go_to']
    assert len(r.model.calls) == 9
    next_messages = r.model.calls[-2]['messages']
    assert any(m.get('tool_call_id') == 'completed-id' and json.loads(m['content'])['data']['target'] == 'done-first'
               for m in next_messages if m.get('role') == 'tool')
