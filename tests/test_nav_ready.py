"""A window starts only while the nav helper offers routes (tools/chat_ladder.nav_not_ready)."""
from tools import chat_ladder as cl


def test_a_recovering_helper_stops_a_window(tmp_path):
    f = tmp_path / "alive.lua"
    f.write_text('return {version=2,epoch="e",state="recovering",updated=1000.0,reason="recovery_unverified:server_identity_changed"}',
                 encoding="utf-8")
    why = cl.nav_not_ready(f, now=1005.0)
    assert why and "recovering" in why and "server_identity_changed" in why and "nav_oracle policy" in why


def test_an_offering_helper_lets_it_start(tmp_path):
    f = tmp_path / "alive.lua"
    f.write_text('return {version=2,epoch="e",state="offered",updated=1000.0,nonce="n"}', encoding="utf-8")
    assert cl.nav_not_ready(f, now=1005.0) is None


def test_a_stale_or_missing_heartbeat_stops_it(tmp_path):
    f = tmp_path / "alive.lua"
    f.write_text('return {version=2,epoch="e",state="offered",updated=1000.0,nonce="n"}', encoding="utf-8")
    assert "stale" in cl.nav_not_ready(f, now=1100.0)
    assert "no heartbeat" in cl.nav_not_ready(tmp_path / "none.lua", now=1100.0)
