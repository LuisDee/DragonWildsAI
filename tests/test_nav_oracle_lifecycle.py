import threading
from tools import nav_oracle as n


class Client:
    def __init__(self, result):
        self.result=result
        self.calls=[]
    def request(self, tool, args, timeout):
        self.calls.append((tool,args))
        return self.result


def request(a, nonce=None):
    return {'version':2,'epoch':a.epoch,'nonce':nonce or a.nonce,'id':7,'from':[0,0,0],'to':[1,1,1]}


def test_consumes_nonce_and_publishes_before_server_call(tmp_path,monkeypatch):
    events=[]
    class CheckClient(Client):
        def request(self,*args,**kw):
            assert events[-1]['state']=='busy' and 'nonce' not in events[-1]
            return super().request(*args,**kw)
    client=CheckClient({'ok':True,'data':{'result':{'ok':True,'points':[[0,0,0],[1,1,1]],'partial':False}}})
    monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua')
    a=n.Authority(client,publish=lambda x:events.append(dict(x)))
    a.heartbeat(); assert events[-1]['state']=='recovering'
    assert not a.accept({'version':2}) and not client.calls
    a.recovered(lambda:True); first=a.nonce; req=request(a)
    assert a.accept(req) and len(client.calls)==1
    assert not a.accept(req) and len(client.calls)==1
    assert a.nonce != first and events[-1]['state']=='offered'
    text=(tmp_path/'resp.lua').read_text(); assert f'epoch="{a.epoch}"' in text and f'nonce="{first}"' in text and 'version=2' in text


def test_unresolved_timeout_never_reoffers_or_resends(tmp_path,monkeypatch):
    events=[]; client=Client({'ok':False,'reason':'timeout'})
    monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua')
    a=n.Authority(client,publish=lambda x:events.append(dict(x))); a.recovered(lambda:True); req=request(a)
    assert a.accept(req) and a.state=='unresolved' and a.nonce is None
    assert not a.accept(req) and len(client.calls)==1
    a.heartbeat(); assert events[-1]['state']=='unresolved' and 'nonce' not in events[-1]
    replacement=n.Authority(client,publish=lambda x:events.append(dict(x)))
    assert replacement.epoch != a.epoch and not replacement.accept(req)
    assert replacement.state=='recovering' and len(client.calls)==1


def test_heartbeat_remains_busy_while_native_call_blocked(tmp_path,monkeypatch):
    entered,release=threading.Event(),threading.Event(); events=[]
    class Slow(Client):
        def request(self,*a,**kw):
            entered.set(); assert release.wait(5)
            return {'ok':True,'data':{'result':{'ok':False,'reason':'no_path'}}}
    monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua')
    a=n.Authority(Slow(None),publish=lambda x:events.append(dict(x))); a.recovered(lambda:True); req=request(a)
    t=threading.Thread(target=a.accept,args=(req,));t.start(); assert entered.wait(5)
    a.heartbeat(); assert events[-1]['state']=='busy' and 'nonce' not in events[-1]
    assert not a.accept(req)
    release.set(); t.join(5); assert not t.is_alive() and a.state=='offered'


def test_foreign_identities_and_bad_request_never_reach_server(tmp_path,monkeypatch):
    client=Client(None);monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua')
    a=n.Authority(client,publish=lambda _:None);a.recovered(lambda:True); req=request(a)
    for changes in ({'epoch':'foreign'},{'nonce':'old'},{'version':1},{'id':True}):
        assert not a.accept({**req,**changes})
    assert not client.calls
    assert a.accept({**req,'from':[0,float('nan'),0]})
    assert not client.calls and 'invalid_args' in (tmp_path/'resp.lua').read_text()


def setup_recovery(tmp_path,monkeypatch):
    import json
    bridge=tmp_path/'bridge';bridge.mkdir()
    for name in ('brain_to_body.jsonl','body_to_brain.jsonl'):
        (bridge/name).write_text('{"type":"old"}\n')
    log=tmp_path/'mod.jsonl'
    start={'ts':'2026-10-28T00:00:00Z','offset':0,'dir':str(bridge)}
    log.write_text(json.dumps({'ts':start['ts'],'event':'mod_loaded','data':{}})+'\n'+
                   json.dumps({'ts':start['ts'],'event':'bridge_started','data':{'dir':str(bridge),'offset':0}})+'\n')
    monkeypatch.setattr(n.paths,'bridge_dir',lambda _:bridge)
    policy={'version':1,'server':{'pid':1,'creation_filetime':'123','image':'C:/server.exe'},
            'bridge_log':str(log),'bridge_started':start,'retired_writers':[{'pid':2,'creation_filetime':'456'}],
            'operator_confirms':{'no_other_nav_writers':True,'no_bridge_reload':True}}
    def process(pid): return policy['server'] if pid==1 else None
    return bridge,log,policy,process


def test_recovery_actual_transport_fifo_and_epoch(tmp_path,monkeypatch):
    from brain.transport import file_transport_pair
    from brain.bridge_client import BridgeClient
    from brain.protocol import result
    bridge,log,policy,process=setup_recovery(tmp_path,monkeypatch)
    client_transport, server_transport = file_transport_pair(bridge,body='server')
    def server():
        messages=server_transport.receive(4)
        assert len(messages)==1 and messages[0]['tool']=='ping'
        server_transport.send(result(messages[0]['id'],{'ok':True,'data':{'pong':True}}))
    t=threading.Thread(target=server);t.start()
    verify=n.recover(policy,BridgeClient(client_transport),process)
    t.join(5); assert not t.is_alive() and verify()
    a=n.Authority(Client(None),publish=lambda _:None); a.recovered(verify)
    assert a.state=='offered' and a.nonce


def test_recovery_missing_policy_incomplete_tail_and_old_writer(tmp_path,monkeypatch):
    import pytest
    bridge,log,policy,process=setup_recovery(tmp_path,monkeypatch)
    client=Client({'ok':True,'data':{'pong':True}})
    for invalid in (None,{}, {**policy,'retired_writers':[]},
                    {**policy,'operator_confirms':{'no_other_nav_writers':True}}):
        with pytest.raises(RuntimeError): n.recover(invalid,client,process)
    with pytest.raises(RuntimeError,match='retired_writer'):
        n.recover(policy,client,lambda pid: policy['server'] if pid==1 else {'pid':2,'creation_filetime':'456'})
    assert not client.calls
    with (bridge/'brain_to_body.jsonl').open('ab') as f: f.write(b'{"type":')
    with pytest.raises(RuntimeError,match='incomplete_jsonl_tail'): n.recover(policy,client,process)
    assert not client.calls


def test_recovery_refuses_timeout_truncate_regrow_and_reload(tmp_path,monkeypatch):
    import json,pytest
    bridge,log,policy,process=setup_recovery(tmp_path,monkeypatch)
    class Mutating:
        def __init__(self,mutation,reply): self.mutation,self.reply=mutation,reply
        def request(self,*a,**kw): self.mutation();return self.reply
    good={'ok':True,'data':{'pong':True}}
    with pytest.raises(RuntimeError,match='barrier'):
        n.recover(policy,Mutating(lambda:None,{'ok':False,'reason':'timeout'}),process)
    incoming=bridge/'brain_to_body.jsonl'; old=incoming.read_bytes()
    def change(): incoming.write_bytes(b' '+old)
    with pytest.raises(RuntimeError,match='continuity'): n.recover(policy,Mutating(change,good),process)
    incoming.write_bytes(old)
    duplicate=json.dumps({'event':'bridge_started','ts':policy['bridge_started']['ts'],
                          'data':{'dir':str(bridge),'offset':0}})+'\n'
    def reload():
        with log.open('a') as f: f.write(duplicate)
    with pytest.raises(RuntimeError,match='continuity'): n.recover(policy,Mutating(reload,good),process)


def test_changed_continuity_before_or_after_call_never_offers(tmp_path,monkeypatch):
    monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua');checks=iter([True,False]); client=Client({'ok':True,'data':{'result':{'ok':False,'reason':'no_path'}}})
    a=n.Authority(client,publish=lambda _:None);a.recovered(lambda:next(checks));assert a.accept(request(a))
    assert a.state=='unresolved' and 'recovery_continuity_changed' in (tmp_path/'resp.lua').read_text()
    b=n.Authority(client,publish=lambda _:None);b.recovered(lambda:False);assert b.accept(request(b))
    assert b.state=='unresolved' and len(client.calls)==1


def test_overflow_metres_refused_before_native(tmp_path,monkeypatch):
    monkeypatch.setattr(n,'RESP',tmp_path/'resp.lua');client=Client(None)
    a=n.Authority(client,publish=lambda _:None);a.recovered(lambda:True)
    assert a.accept({**request(a),'from':[1e308,0,0]}) and not client.calls
    assert 'invalid_args' in (tmp_path/'resp.lua').read_text()


def test_unreadable_process_identity_cannot_be_treated_as_absent(tmp_path,monkeypatch):
    import pytest
    bridge,log,policy,process=setup_recovery(tmp_path,monkeypatch)
    client=Client({'ok':True,'data':{'pong':True}})
    def denied(pid):
        if pid==2: raise OSError('access denied')
        return process(pid)
    with pytest.raises(OSError): n.recover(policy,client,denied)
    assert not client.calls


def test_serve_and_cli_share_exclusive_lock(tmp_path):
    import subprocess,sys
    from tools.live_queue import single_instance
    lock=tmp_path/'oracle.lock'
    code=('from pathlib import Path; from tools.live_queue import single_instance; '
          'p=Path(__import__("sys").argv[1]); c=single_instance(p); '
          'ok=c.__enter__(); print("owned" if ok else "blocked"); c.__exit__(None,None,None)')
    with single_instance(lock) as owned:
        assert owned
        proc=subprocess.run([sys.executable,'-c',code,str(lock)],capture_output=True,text=True,timeout=15)
        assert proc.returncode==0 and proc.stdout.strip()=='blocked'
    proc=subprocess.run([sys.executable,'-c',code,str(lock)],capture_output=True,text=True,timeout=15)
    assert proc.returncode==0 and proc.stdout.strip()=='owned'
