"""The reflected signatures combat.lua hooks or reads (velgar.md gaps 1, 3, 4) exist in the class dump with the
shapes the Lua expects. A hook path or a param shape that drifts after a patch would make a RegisterHook miss or
a read return nil; this catches it offline (pcall can't catch a native crash, so check before going live)."""
import re
from pathlib import Path

import pytest

DUMP = Path(__file__).resolve().parents[1] / "dumps/26161880/CXXHeaderDump"
DOMINION = DUMP / "Dominion.hpp"
ENUMS = DUMP / "Dominion_enums.hpp"

pytestmark = pytest.mark.skipif(not DOMINION.exists(), reason="class dump not present")


def class_body(name: str) -> str:
    text = DOMINION.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"\nclass " + re.escape(name) + r" : public [^\n]*\n\{(.*?)\n\}; // Size", text, re.S)
    assert m, name
    return m.group(1)


def test_ai_actions_component_multicasts_are_hookable_with_scalar_params():
    body = class_body("UDominionAIActionsComponent")
    assert "void Multicast_StartAIAction(int32 ActionId);" in body  # a single int: the hook reads it as a scalar
    assert "void Multicast_StopCurrentAIAction();" in body
    assert "class UDominionAIAction* CurrentAction;" in body  # read (a property) on the next tick, not in the hook


def test_boss_phase_is_a_replicated_struct_of_scalars():
    body = class_body("APhasedDragonArenaAILevelData")
    assert "FDragonBossPhase_Runtime PhaseRuntimeData;" in body and "TArray<FDragonBossPhaseData> PhaseData;" in body
    text = DOMINION.read_text(encoding="utf-8", errors="replace")
    rt = re.search(r"struct FDragonBossPhase_Runtime\n\{(.*?)\n\};", text, re.S).group(1)
    assert "uint8 PhaseIndex;" in rt and "bool bTransitioningToNext;" in rt


def test_tracked_status_getters_take_an_enum_scalar():
    body = class_body("UTrackedStatusEffectsComponent")
    for fn in ("GetTrackedStatusEffectAmount", "GetMaxStatusEffectAmount", "GetEffectsExpectedDecayTimeRemaining"):
        assert f"void {fn}(const ETrackedStatusEffect EffectType);" in body, fn
    enums = ENUMS.read_text(encoding="utf-8", errors="replace")
    e = re.search(r"enum class ETrackedStatusEffect \{(.*?)\};", enums, re.S).group(1)
    for name, v in (("Poison", 2), ("Burning", 3), ("Bleeding", 4), ("Slow", 5)):
        assert re.search(rf"\b{name} = {v},", e), name


def test_the_lua_uses_the_same_names():
    lua = (Path(__file__).resolve().parents[1] / "client_mod/scripts/combat.lua").read_text(encoding="utf-8")
    assert "/Script/Dominion.DominionAIActionsComponent:Multicast_StartAIAction" in lua
    assert "/Script/Dominion.DominionAIActionsComponent:Multicast_StopCurrentAIAction" in lua
    assert '"PhasedDragonArenaAILevelData"' in lua and "PhaseRuntimeData.PhaseIndex" in lua and "bTransitioningToNext" in lua
