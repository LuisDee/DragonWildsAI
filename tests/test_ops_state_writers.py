"""Operations state must survive transient locks and preserve old data on permanent denial."""
import json

import pytest

from brain import fileio
from tools import client_slot, live_queue, scenario_run


@pytest.mark.parametrize("kind", ["lease", "slot", "queue"])
@pytest.mark.parametrize("permanent", [False, True])
def test_ops_state_writer_replacement_denial(tmp_path, monkeypatch, kind, permanent):
    path = tmp_path / "state.json"
    path.write_text('{"old":true}', encoding="utf-8")
    if kind == "lease":
        monkeypatch.setattr(scenario_run, "STATE_DIR", tmp_path)
        monkeypatch.setattr(scenario_run, "LEASE", path)
        write = lambda: scenario_run.write_lease("dev", 2, "test")
        expected = "target"
    elif kind == "slot":
        monkeypatch.setattr(client_slot, "STATE", path)
        write = lambda: client_slot._save({"holder": None})
        expected = "holder"
    else:
        write = lambda: live_queue.save_state({"checks": {}}, path)
        expected = "checks"
    real_replace = fileio.os.replace
    attempts = []

    def denied(source, destination):
        if destination == path:
            attempts.append(source)
            if permanent or len(attempts) < 3:
                raise PermissionError("replacement denied")
        return real_replace(source, destination)

    monkeypatch.setattr(fileio.os, "replace", denied)
    if permanent:
        with pytest.raises(PermissionError):
            write()
        assert path.read_text(encoding="utf-8") == '{"old":true}'
        assert len(attempts) == 5
    else:
        write()
        assert expected in json.loads(path.read_text(encoding="utf-8"))
        assert len(attempts) == 3
    assert not list(tmp_path.glob("*.tmp"))
