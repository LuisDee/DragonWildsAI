import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from brain.agent import Agent  # noqa: E402
from brain.controller import Controller  # noqa: E402
from brain.executor import Executor  # noqa: E402
from brain.jsonl_log import JsonlLogger  # noqa: E402
from brain.llm import FakeLLM  # noqa: E402
from brain.mock import MockGame  # noqa: E402
from brain.planner import Planner  # noqa: E402
from brain.state_store import StateStore  # noqa: E402


class Rig:
    """A fully wired agent on the mock game with scripted LLMs."""

    def __init__(self, tmp_path: Path, max_attempts: int = 3, max_replans: int = 2):
        self.game = MockGame.default_world()
        self.store = StateStore(tmp_path / "state")
        self.log = JsonlLogger(tmp_path / "logs" / "brain.jsonl")
        self.controller_llm = FakeLLM(model="fake/controller")
        self.planner_llm = FakeLLM(model="fake/planner")
        self.executor = Executor(self.game, self.store, self.log, max_attempts=max_attempts)
        self.planner = Planner(self.planner_llm, self.store.skills, self.log)
        self.controller = Controller(self.controller_llm, self.game, self.store, self.log)
        self.agent = Agent(self.game, self.controller, self.planner, self.executor, self.store, self.log,
                           max_replans=max_replans)

    def companion_said(self) -> list[str]:
        return [text for who, text in self.game.chat if who == "companion"]

    def calls(self, tool: str) -> list[dict]:
        return [args for name, args in self.game.calls if name == tool]


@pytest.fixture
def rig(tmp_path):
    return Rig(tmp_path)
