import copy
import json

from brain.controller import Decision, _model_read_view
from brain.interface import Reason
from brain.jsonl_log import read_jsonl
from brain.llm import FakeLLM, ToolCall
from tests.conftest import Rig


def fixture():
    def scope(n):
        return {'status':'partial','reason':'unverified','count_semantics':'lower_bound',
                'gaps':[{'raw':i,'reason':'unverified_slot'} for i in range(n)]}
    return {'ok':True,'data':{'hotbar':[{'item':'item_a','name':'Apple','count':2}],
            'bag':[{'item':'item_b','name':'Stick','count':3}], 'unmapped':[],
            'read_status':{'carried':scope(166),'loadout':scope(8),'personal':scope(20),
                           'held':{'right':{'status':'unknown','gaps':[]},
                                   'left':{'status':'complete','gaps':[]}}}}}


def test_controller_real_loop_keeps_raw_enriched_and_ids(tmp_path):
    rig=Rig(tmp_path); raw=fixture(); initial=copy.deepcopy(raw)
    rig.game.call=lambda name,args: raw if name=='inventory' else {'ok':False}
    rig.controller_llm.push(FakeLLM.say('',ToolCall('inventory',{},'read-a'),ToolCall('inventory',{},'read-b')))
    rig.controller_llm.push(FakeLLM.say('noted'))
    decision=rig.controller.decide('Tester','What do you have?',rig.game.get_state()['data'],None)
    messages=rig.controller_llm.calls[1]['messages']
    results=[m for m in messages if m.get('role')=='tool' and m.get('name')=='inventory']
    assert [m['tool_call_id'] for m in results]==['read-a','read-b']
    view=json.loads(results[0]['content']); data=view['data']
    assert data['hotbar'][0]['name']=='Apple' and data['hotbar'][0]['count']==2
    assert data['bag'][0]['name']=='Stick' and data['bag'][0]['count']==3
    carried=data['read_status']['carried']; assert carried['status']=='partial' and carried['count_semantics']=='lower_bound'
    assert carried['gaps']==[{'reason':'unverified_slot','count':166,'sample_raw':[0,1,2],'omitted':163,'truncated':True}]
    assert data['read_status']['loadout']['gaps'][0]['count']==8
    assert data['read_status']['personal']['gaps'][0]['count']==20
    assert data['read_status']['held']['right']['status']=='unknown'
    assert data['read_status']['held']['left']['status']=='complete'
    assert raw==initial and len(decision.inventory['read_status']['carried']['gaps'])==166
    logged=[x for x in read_jsonl(rig.log.path) if x.get('kind')=='tool_result' and x.get('tool')=='inventory']
    assert len(logged)==2 and all(x['result']==initial for x in logged)
    enriched_size=len(json.dumps({'ok':True,'data':decision.inventory},ensure_ascii=False).encode())
    view_size=len(results[0]['content'].encode())
    assert view_size < enriched_size * .35
    print(f'enriched_raw_bytes={enriched_size} model_view_bytes={view_size}')


def test_unique_rich_malformed_other_gaps_and_copy_isolation():
    raw={'ok':True,'data':{'other':{'gaps':[{'raw':i,'reason':'outside'} for i in range(9)]},
         'read_status':{'carried':{'status':'partial','gaps':[
             *[{'raw':i,'reason':'repeat'} for i in range(6)],
             {'raw':9,'reason':'rare'}, {'raw':10,'reason':'repeat','detail':'distinct'},
             {'raw':'bad','reason':'repeat'}, {'unexpected':'value'}, None]},
             'held':{'right':{'status':'unknown','gaps':[{'raw':0,'reason':'once'}]},
                     'left':{'status':'complete','gaps':[]}}}}}
    original=copy.deepcopy(raw); view=_model_read_view(raw)
    gs=view['data']['read_status']['carried']['gaps']
    assert gs[0]=={'reason':'repeat','count':6,'sample_raw':[0,1,2],'omitted':3,'truncated':True}
    assert gs[1:]==[{'raw':9,'reason':'rare'},{'raw':10,'reason':'repeat','detail':'distinct'},
                    {'raw':'bad','reason':'repeat'},{'unexpected':'value'},None]
    assert view['data']['other']==raw['data']['other'] and raw==original
    view['data']['read_status']['held']['left']['status']='changed'
    assert raw==original


def test_empty_missing_and_complete_status_stay_unchanged():
    for raw in ({'ok':True,'data':{}}, {'ok':True,'data':{'read_status':{'carried':{'status':'complete','gaps':[]}}}},
                {'ok':True,'data':{'read_status':{'carried':{'status':'unknown','gaps':'bad'}}}}):
        assert _model_read_view(raw)==raw


def test_cant_yet_preserves_failure_details_and_notes(tmp_path):
    rig=Rig(tmp_path); raw={'ok':False,'reason':Reason.NOT_IMPLEMENTED,'detail':'specific problem',
                            'data':{'read_status':{'carried':{'status':'unknown',
                             'gaps':[{'raw':i,'reason':'error'} for i in range(5)]}}}}
    rig.game.call=lambda name,args: raw
    got=rig.controller._read(ToolCall('inventory',{},'read'),Decision())
    assert got['reason']==Reason.NOT_IMPLEMENTED and got['detail']=='specific problem'
    assert got['note']=="you can't inventory yet" and got['data']['read_status']['carried']['gaps'][0]['count']==5
    assert len(raw['data']['read_status']['carried']['gaps'])==5
    raw['note']='existing specific note'; got=rig.controller._read(ToolCall('inventory',{},'read'),Decision())
    assert got['note']=='existing specific note'


def test_read_in_next_turn_uses_same_view_without_compacting_action_result(tmp_path):
    from brain.llm import assistant_message
    rig=Rig(tmp_path); raw=fixture(); rig.game.call=lambda name,args: raw
    action={'ok':False,'reason':'failure','data':{'read_status':{'carried':{'gaps':[
        {'raw':i,'reason':'keep_action_history'} for i in range(6)]}}}}
    decision=Decision(messages=[assistant_message(FakeLLM.say('',ToolCall('go_to',{'target':'camp'},'act')))])
    rig.controller_llm.push(FakeLLM.say('',ToolCall('inventory',{},'read-next')))
    rig.controller_llm.push(FakeLLM.say('done'))
    rig.controller.next_turn(decision,{'act':action},state={},failed=True)
    messages=rig.controller_llm.calls[1]['messages']
    action_message=next(x for x in messages if x.get('tool_call_id')=='act')
    read_message=next(x for x in messages if x.get('tool_call_id')=='read-next')
    assert json.loads(action_message['content'])==action
    assert json.loads(read_message['content'])['data']['read_status']['carried']['gaps'][0]['count']==166
