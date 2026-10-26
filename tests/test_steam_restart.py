"""tools/steam_restart.py: a Steam restart is refused unless Steam can log itself back in (BUGS L35)."""
from __future__ import annotations

from tools.steam_restart import remembered_login

GOOD = '''"users"
{
	"76561198614193617"
	{
		"AccountName"		"bootymaxer"
		"PersonaName"		"Claude"
		"RememberPassword"		"1"
		"MostRecent"		"1"
	}
}'''


def test_remembered_login_passes():
    assert remembered_login(GOOD, "bootymaxer") == (True, "remembered login present")


def test_the_2026_10_26_state_is_refused():
    ok, why = remembered_login('"users"\n{\n}\n', "")  # what the VM had when Steam was restarted (L35)
    assert not ok and "AutoLoginUser is empty" in why


def test_refused_without_remember_or_for_another_account():
    assert remembered_login(GOOD.replace('"1"\n\t\t"MostRecent"', '"0"\n\t\t"MostRecent"'), "bootymaxer")[0] is False
    assert remembered_login(GOOD, "someone_else")[0] is False
    assert remembered_login('"users"\n{\n}\n', "bootymaxer") == (False, "bootymaxer is not in config/loginusers.vdf")
