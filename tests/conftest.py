import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain.agent import Agent  # noqa: E402
from brain.controller import Controller  # noqa: E402
from brain.executor import Executor  # noqa: E402
from brain.interface import GameInterface  # noqa: E402
from brain.jsonl_log import JsonlLogger  # noqa: E402
from brain.llm import FakeLLM  # noqa: E402
from brain.mock import MockGame  # noqa: E402
from brain.planner import Planner  # noqa: E402
from brain.skill_library import SkillLibrary  # noqa: E402
from brain.state_store import SkillRegistry, StateStore  # noqa: E402


class Rig:
    """A fully wired agent with scripted LLMs, on the mock game unless ``game`` is given."""

    def __init__(self, tmp_path: Path, max_attempts: int = 3, max_replans: int = 2,
                 game: GameInterface | None = None, skills: SkillRegistry | None = None,
                 library: bool = False, available_tools: set[str] | None = None):
        self.game = game if game is not None else MockGame.default_world()
        self.store = StateStore(tmp_path / "state", skills)
        self.log = JsonlLogger(tmp_path / "logs" / "brain.jsonl")
        self.controller_llm = FakeLLM(model="fake/controller")
        self.planner_llm = FakeLLM(model="fake/planner")
        # The skill library (learning after verified goals) only when a test asks for it.
        self.library = SkillLibrary(tmp_path / "skills", self.log) if library else None
        self.executor = Executor(self.game, self.store, self.log, max_attempts=max_attempts)
        self.planner = Planner(self.planner_llm, self.store.skills, self.log)
        self.controller = Controller(self.controller_llm, self.game, self.store, self.log,
                                     skills=self.library, available_tools=available_tools)
        self.agent = Agent(self.game, self.controller, self.planner, self.executor, self.store, self.log,
                           max_replans=max_replans, skills=self.library)

    def companion_said(self) -> list[str]:
        return [text for who, text in self.game.chat if who == "companion"]

    def calls(self, tool: str) -> list[dict]:
        return [args for name, args in self.game.calls if name == tool]


@pytest.fixture
def rig(tmp_path):
    return Rig(tmp_path)
