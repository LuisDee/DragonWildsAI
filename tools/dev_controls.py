"""DEV control diagnostics: strict script validation and observed execution.

The external operator owns the client slot and watchdog. It never writes goal
validity records. Import and ``--describe`` are read-only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import time
import uuid
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from brain.interface import BODY_TOOLS, TOOLS, validate_args
from evals.bench import hashes
from evals.bench.agents import bind
from evals.bench.devrun import judge_dev
from evals.bench.observer import ObservedGame
from evals.bench.runner import entry_hash
from evals.bench.spec import case_hash, load_cases

CONTROLS = ("oracle", "do_nothing", "claims_only", "wrong_action", "alt_means", "partial")
# Narrow initial fixture subset: each is one server request, with no body calls,
# loops, character changes, world restoration or emulated outcomes.
FIXTURES = {"unlock", "grant_runes"}
INFRA_REASONS = {"timeout", "body_restarted", "lost_by_body", "paused", "no_reply", "interrupted"}


class Blocked(RuntimeError):
    """The run cannot make a reliable diagnostic assertion."""


def _refs(value: Any) -> set[str]:
    if isinstance(value, str) and value.startswith("$"):
        return {value[1:].split(".", 1)[0]}
    if isinstance(value, dict):
        return set().union(*(_refs(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(_refs(v) for v in value)) if value else set()
    return set()


def _fixture(step: Any, names: set[str]) -> tuple[dict, str | None]:
    if not isinstance(step, dict) or not isinstance(step.get("verb"), str):
        raise Blocked("invalid fixture shape")
    verb = step["verb"]
    if verb not in FIXTURES:
        raise Blocked(f"unsupported fixture: {verb}")
    allowed = {"verb", "as", "purpose", "spell"} if verb == "unlock" else {"verb", "as", "purpose", "runes"}
    if set(step) - allowed:
        raise Blocked("unsupported fixture arguments")
    if verb == "unlock" and (not isinstance(step.get("spell"), str) or not step["spell"]):
        raise Blocked("unlock requires spell")
    if verb == "grant_runes" and (not isinstance(step.get("runes"), dict) or not step["runes"] or
            any(not isinstance(k, str) or not k or type(v) is not int or v <= 0 for k, v in step["runes"].items())):
        raise Blocked("grant_runes requires positive integer counts")
    name = step.get("as")
    if name is not None and (not isinstance(name, str) or not name.isidentifier() or name in names):
        raise Blocked("invalid or duplicate fixture binding")
    if _refs(step) - names:
        raise Blocked("undeclared fixture binding")
    return dict(step), name


def prepare(case: Any, control: str) -> tuple[list[dict], list[dict]]:
    """Validate the entire frozen plan before any fixture or client action."""
    if control not in CONTROLS or "dev" not in case.targets:
        raise Blocked("unsupported control or target")
    if case.fixtures.state_snapshot != "empty" or (case.fixtures.model_extra or {}).get("character"):
        raise Blocked("character or snapshot requirement is unsupported")
    if case.fixtures.requires or case.fixtures.player_body or case.fixtures.scene or case.fixtures.model_extra:
        raise Blocked("fixture requirements are unsupported")
    names: set[str] = set()
    fixtures = []
    for raw in case.fixtures.setup:
        step, name = _fixture(raw, names)
        fixtures.append(step)
        if name:
            names.add(name)
    if control in case.controls.na:
        raise Blocked("explicit N/A is recorded only; not executable")
    if control == "oracle":
        steps = case.oracle.get("dev")
    elif control == "do_nothing":
        steps = [{"wait_s": case.limits.wall_s}]
    elif control == "claims_only":
        steps = [{"say": "Done, all sorted!"}]
    else:
        steps = getattr(case.controls, control)
    if not isinstance(steps, list) or not steps:
        raise Blocked("missing, non-list or empty control script")
    if not math.isfinite(case.limits.wall_s) or not 0 < case.limits.wall_s <= 1800:
        raise Blocked("invalid wall window")
    for step in steps:
        if not isinstance(step, dict):
            raise Blocked("step is not an object")
        if set(step) <= {"tool", "args"} and "tool" in step:
            if (not isinstance(step["tool"], str) or step["tool"] not in BODY_TOOLS or
                    not isinstance(step.get("args", {}), dict)):
                raise Blocked("invalid tool step")
            model = TOOLS[step["tool"]][0]
            fields = model.model_fields
            args = step.get("args", {})
            if set(args) - set(fields) or any(field.is_required() and name not in args for name, field in fields.items()):
                raise Blocked("unknown or missing tool arguments")
        elif set(step) == {"say"}:
            if not isinstance(step["say"], str) or not step["say"]:
                raise Blocked("invalid say step")
        elif set(step) == {"wait_s"}:
            value = step["wait_s"]
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= case.limits.wall_s:
                raise Blocked("invalid wait")
        else:
            raise Blocked("unknown or ambiguous step")
        if _refs(step) - names:
            raise Blocked("undeclared script binding")
    return fixtures, [dict(s) for s in steps]


class Journal:
    """Append and flush each event to a unique file; no mutation or promotion."""
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / f"control-{uuid.uuid4().hex}.jsonl"
        self._file = self.path.open("x", encoding="utf-8")

    def record(self, kind: str, **data: Any) -> None:
        self._file.write(json.dumps({"kind": kind, "wall": time.time(), **data}, ensure_ascii=False, default=str) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()


class GuardedGame:
    """Final admission check immediately before each body dispatch."""
    def __init__(self, inner: Any, admission: Callable[[str], None]):
        self.inner, self.admission = inner, admission

    def call(self, tool: str, args: dict) -> Any:
        self.admission("dispatch:" + tool)
        return self.inner.call(tool, args)

    def say(self, text: str) -> Any:
        self.admission("dispatch:say")
        return self.inner.say(text)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)


def verdict(control: str, result: str, reason: str | None, baseline: tuple[str, str | None]) -> str:
    if baseline != ("fail", "not_achieved"):
        return "blocked_baseline"
    if control == "oracle":
        return "observed_expected" if result == "pass" else "blocked_oracle"
    return "observed_expected" if (result, reason) == ("fail", "not_achieved") else "blocked_negative"


def execute(case: Any, control: str, *, dev: Any, game: Any, admission: Callable[[str], None],
            journal: Journal, metadata: dict, clock: Callable[[], float] = time.monotonic,
            sleep: Callable[[float], None] = time.sleep) -> dict:
    """Diagnostic core for an audited adapter, not an admission mechanism.

    Caller must own the slot/watchdog, provide guard-wrapped DevTarget transports,
    prove fresh identities at each effect boundary, and retain slot on ambiguity.
    """
    started = clock()
    record = {"control": control, "case": case.id, "case_hash": case_hash(case),
              "scorer": hashes.scorer_hash(), "body": hashes.body_hash(), "entry_hash": entry_hash(case),
              "catalog_build": hashes.game_build(), "actual_client_build": metadata.get("actual_client_build"),
              "metadata": metadata, "na": dict(case.controls.na), "promotion": "disabled",
              "status": "blocked", "retain_slot": True}
    journal.record("start", **record)
    observed = None
    try:
        fixtures, steps = prepare(case, control)
        deadline = started + float(case.limits.wall_s) + 120.0
        def guard(where: str) -> None:
            if clock() >= deadline:
                raise Blocked("deadline exceeded; action state unknown")
            admission(where)
            dev.guard(where, {})
        bindings: dict[str, Any] = {}
        for raw in fixtures:
            step = bind(raw, bindings)
            verb = step.pop("verb")
            name = step.pop("as", None)
            guard("fixture")
            journal.record("fixture_intent", verb=verb, args=step)
            out = dev.setup(verb, **step)
            journal.record("fixture_result", verb=verb, result=out)
            if name:
                bindings[name] = out
        # Resolve every binding before the first action; missing concrete values fail closed.
        steps = bind(steps, bindings)
        for step in steps:
            if "tool" in step:
                try:
                    validate_args(step["tool"], step.get("args", {}))
                except Exception as exc:
                    raise Blocked("invalid concrete tool arguments") from exc
        guard("referee_start")
        journal.record("referee_start_intent")
        dev.referee_start()
        guarded_game = GuardedGame(game, guard)
        observed = ObservedGame(guarded_game, dev.probe, dev.referee_events, guard=lambda tool, args: guard("action:" + tool))
        guard("probe_start")
        observed.start()
        observed.rec.probe1 = observed.rec.probe0
        baseline, baseline_reason, succ, ctx = judge_dev(case, observed, bindings)
        journal.record("baseline", result=baseline, reason=baseline_reason, probe=observed.rec.probe0,
                       detail=succ.detail, missing=succ.missing, mismatches=ctx["mismatches"])
        observed.rec.probe1 = None
        if (baseline, baseline_reason) != ("fail", "not_achieved"):
            raise Blocked("baseline already satisfied or unverifiable")
        for step in steps:
            guard("step")
            journal.record("step_intent", step=step)
            if "tool" in step:
                reply = observed.call(step["tool"], step.get("args", {}))
                journal.record("step_result", reply=reply)
                if (not isinstance(reply, dict) or reply.get("ok") is not True or
                        reply.get("reason") in INFRA_REASONS):
                    raise Blocked("action failed or completion unknown")
            elif "say" in step:
                reply = observed.say(step["say"])
                journal.record("step_result", reply=reply)
                if not isinstance(reply, dict) or reply.get("ok") is not True:
                    raise Blocked("claim could not be delivered")
            else:
                end = clock() + float(step["wait_s"])
                while clock() < end:
                    guard("wait")
                    sleep(min(1.0, end - clock()))
                journal.record("wait_complete", seconds=step["wait_s"])
        guard("probe_finish")
        observed.finish()
        result, reason, succ, ctx = judge_dev(case, observed, bindings)
        record.update(status=verdict(control, result, reason, (baseline, baseline_reason)), result=result, reason=reason)
        journal.record("judgement", result=result, reason=reason, detail=succ.detail, missing=succ.missing,
                       mismatches=ctx["mismatches"], probe0=observed.rec.probe0, probe1=observed.rec.probe1,
                       observations=[asdict(x) for x in observed.rec.observations], referee=observed.rec.referee,
                       said=observed.rec.said, reads=observed.rec.reads, bindings=bindings)
    except Exception as exc:
        record.update(status="blocked", error=f"{type(exc).__name__}: {exc}")
        journal.record("error", error=record["error"], observations=[asdict(x) for x in observed.rec.observations] if observed else [])
    finally:
        # No implicit cleanup: another component may own work, and a timeout is not cancellation.
        # The root operator must inspect and clean up the owned referee and retain the slot until idle.
        record["elapsed_s"] = clock() - started
        journal.record("end", **record)
    return record


def data(reply: Any) -> dict:
    if not isinstance(reply, dict) or reply.get("ok") is not True or not isinstance(reply.get("data"), dict):
        raise Blocked("bridge status unavailable")
    return reply["data"]


def idle(state: dict, ping: dict, arb: dict, bridge: dict, move: dict, name: str, pawn: str) -> bool:
    """Adapted from the private pilot: missing status is not evidence of idle."""
    try:
        st, pi, ar, br, mv = map(data, (state, ping, arb, bridge, move))
        return (st.get("name") == name and st.get("pawn") == pawn and st.get("dead") is False and
                st.get("paused") is not True and all(k in pi for k in ("action", "waiters", "started")) and
                pi["started"] is not None and pi["action"] is None and pi["waiters"] == [] and
                isinstance(ar.get("counts"), dict) and isinstance(ar.get("history"), list) and
                "suspended" in ar and ar["suspended"] == [] and ar.get("owner") is None and
                "paused" in br and "action" in br and br["paused"] is False and br["action"] is None and
                mv.get("mode") == "idle")
    except Blocked:
        return False


def source_attestation(root: Path, manifest_path: Path) -> dict:
    """Check published source bytes and tracked deployed checkout, never modify it."""
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        published = json.loads(manifest_path.with_name("publication.json").read_text(encoding="utf-8"))
        if not isinstance(manifest, dict) or not manifest or published.get("source_bytes_verified") is not True:
            raise Blocked("publication evidence missing")
        # Publication includes documentation which can change later; check its code paths.
        code = {p: v for p, v in manifest.items() if p.startswith(("client_mod/scripts/", "brain/"))}
        if not code or not any(p.startswith("client_mod/scripts/") for p in code):
            raise Blocked("publication has no client source proof")
        for name, digest in code.items():
            p = (root / name).resolve()
            if not p.is_relative_to(root.resolve()) or hashlib.sha256(p.read_bytes()).hexdigest() != digest:
                raise Blocked("published source bytes changed: " + name)
        def git(*args: str) -> str:
            result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=10, check=True)
            return result.stdout.strip()
        head = git("rev-parse", "HEAD")
        if git("status", "--porcelain", "--untracked-files=no"):
            raise Blocked("deployed tracked tree dirty")
        return {"head": head, "publication_commit": published.get("commit"), "manifest_sha256":
                hashlib.sha256(manifest_path.read_bytes()).hexdigest(), "checked_files": code}
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise Blocked("cannot verify publication source") from exc


def backup_attestation(manifest_path: Path, root: Path, world: str) -> dict:
    """Validate copied snapshots; never compare or modify the active save."""
    import re
    try:
        path = manifest_path.resolve(strict=True)
        if not path.is_relative_to((root / "logs/recovery").resolve()) or not path.is_file():
            raise Blocked("backup manifest must be a recovery file")
        raw = path.read_bytes()
        manifest = json.loads(raw)
        if not isinstance(manifest, dict) or manifest.get("world") != world or manifest.get("character") != "ClaudeDev":
            raise Blocked("backup identity mismatch")
        files = manifest.get("files")
        if not isinstance(files, list) or not files:
            raise Blocked("backup manifest has no files")
        expected = {"world_state", "skills", "envelopes", "client_state", "world_save"}
        found, copies = set(), set()
        for row in files:
            if not isinstance(row, dict) or set(row) != {"category", "source", "copy", "sha256"}:
                raise Blocked("malformed backup entry")
            category, source, copy, digest = (row[k] for k in ("category", "source", "copy", "sha256"))
            if (category not in expected or not isinstance(source, str) or not source or
                    not isinstance(copy, str) or not copy or not isinstance(digest, str) or
                    not re.fullmatch(r"[0-9a-fA-F]{64}", digest)):
                raise Blocked("invalid backup metadata")
            relative = Path(copy)
            if relative.is_absolute() or ".." in relative.parts:
                raise Blocked("backup copy escapes manifest directory")
            target = (path.parent / relative).resolve(strict=True)
            if not target.is_relative_to(path.parent) or not target.is_file() or target in copies:
                raise Blocked("backup copy missing, duplicate or outside snapshot")
            src = source.replace("\\", "/").lower().rstrip("/")
            token = world.lower()
            if category == "world_state" and f"/logs/state/worlds/{token}/" not in "/" + src.lstrip("/"):
                raise Blocked("world state source does not match selected world")
            if category == "skills" and f"/data/skills/{token}/" not in "/" + src.lstrip("/"):
                raise Blocked("skills source does not match selected world")
            if category == "envelopes" and "/data/envelopes/" not in "/" + src.lstrip("/"):
                raise Blocked("envelope source missing")
            if category == "client_state" and "/client_io/state/" not in "/" + src.lstrip("/"):
                raise Blocked("client state source missing")
            if category == "world_save" and "save" not in src:
                raise Blocked("world save source missing")
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest.lower():
                raise Blocked("backup copy digest mismatch")
            copies.add(target)
            found.add(category)
        if found != expected:
            raise Blocked("backup coverage incomplete: " + ", ".join(sorted(expected - found)))
        return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(), "world": world,
                "character": "ClaudeDev", "categories": sorted(found), "files": len(files)}
    except (OSError, ValueError, TypeError) as exc:
        raise Blocked("backup manifest or copied files unreadable") from exc


def process_start(pid: int) -> str:
    # Admission-only process identity, no process changes.
    try:
        p = subprocess.run(["powershell", "-NoProfile", "-Command",
                            f"(Get-Process -Id {int(pid)} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')"],
                           capture_output=True, text=True, timeout=10, check=True)
        if not p.stdout.strip(): raise Blocked("client process start unknown")
        return p.stdout.strip()
    except (OSError, subprocess.SubprocessError) as exc:
        raise Blocked("client process unavailable") from exc


class LiveAdmission:
    """Read-only owner/target/identity/idle guard, rechecked at each boundary."""
    def __init__(self, root: Path, dev: Any, body: Any, owner: str, pawn: str, world: str,
                 endpoint: str, deadline: float, journal: Journal):
        self.root, self.dev, self.body = root, dev, body
        self.owner, self.pawn, self.world, self.endpoint = owner, pawn, world, endpoint
        self.deadline, self.journal = deadline, journal
        self.pid = self.started = self.build = self.bridge_generation = None

    def __call__(self, where: str) -> None:
        from brain.worlds import resolve_world_guid
        from tools import client_slot
        if time.monotonic() >= self.deadline:
            raise Blocked("operator deadline expired")
        if any((self.root / "logs" / f).exists() for f in ("client.hold", "client.stopped")):
            raise Blocked("client held")
        try:
            slot = json.loads((self.root / "logs/state/client_slot.json").read_text(encoding="utf-8"))
            h = client_slot.holder(slot)
            if not h or h.get("owner") != self.owner or h.get("reserved"):
                raise Blocked("slot not owned")
            status = json.loads((self.root / "logs/state/client_status.json").read_text(encoding="utf-8-sig"))
            # Watchdog may emit seven fractional digits.
            stamp = status["ts"].replace("Z", "+00:00")
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(stamp)).total_seconds()
            pid, build = status.get("pid"), status.get("build")
            if (not 0 <= age <= 180 or status.get("state") not in ("in_world", "ok_unprobed") or
                    status.get("dev_server") is not True or status.get("map") != "L_World" or
                    status.get("logged_in") is not True or status.get("pawn") != self.pawn or
                    type(pid) is not int or pid <= 0 or not isinstance(build, str) or not build):
                raise Blocked("client status is stale or identity unknown")
        except (OSError, ValueError, KeyError, TypeError) as exc:
            raise Blocked("slot or client status unreadable") from exc
        if self.pid is not None and (pid != self.pid or build != self.build):
            raise Blocked("client changed")
        if self.pid is not None and process_start(pid) != self.started:
            raise Blocked("client process generation changed")
        if not self.dev.forbidden() or self.dev.joined() != self.endpoint:
            raise Blocked("effective DEV endpoint or forbidden set changed")
        self.dev.guard(where, {})
        state = self.body.get_state()
        ping = self.body.request("ping", {}, timeout=5)
        arb = self.body.request("arbiter_status", {}, timeout=5)
        bridge = self.body.request("bridge_status", {}, timeout=5)
        move = self.body.request("move_status", {}, timeout=5)
        if not idle(state, ping, arb, bridge, move, "ClaudeDev", self.pawn):
            raise Blocked("body busy, foreign, or identity unverified; retain slot")
        generation = data(ping)["started"]
        if self.bridge_generation is not None and generation != self.bridge_generation:
            raise Blocked("bridge generation changed")
        actual_world, world_source = resolve_world_guid(self.body, data(state))
        if actual_world != self.world or world_source == "default":
            raise Blocked("world identity unverified")
        if self.pid is None:
            self.pid, self.build, self.bridge_generation = pid, build, generation
            self.started = process_start(pid)
        self.journal.record("admission", where=where, slot=h, status=status, state=state, ping=ping,
                            arbiter=arb, bridge=bridge, move=move, world=actual_world, world_source=world_source)


def execute_live(args: Any, selected: Any) -> int:
    """Operator-owned live invocation. This function must be cold-reviewed before use."""
    from brain.bridge_client import BridgeClient
    from brain.transport import file_transport_pair
    from evals.bench.devrun import default_dev
    root = hashes.ROOT.resolve()
    if root != Path(r"C:\gameserver").resolve():
        raise Blocked("live control requires deployed checkout")
    if not args.operator_watchdog:
        raise Blocked("external operator watchdog required")
    case_file = Path(args.execute).resolve()
    if not any(case_file.is_relative_to(root / "evals/bench" / part) for part in ("cases", "goal_cases")):
        raise Blocked("case file outside frozen case directories")
    try:
        subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", str(case_file)],
                       capture_output=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Blocked("case file is not tracked") from exc
    if args.deadline_s <= selected.limits.wall_s:
        raise Blocked("deadline cannot cover full case window and setup")
    backup = Path(args.backup)
    prepare(selected, args.control)  # no live calls before complete syntax validation
    attestation = source_attestation(root, Path(args.publication_manifest))
    dev = default_dev()
    body = BridgeClient(file_transport_pair(body="client", channel="debug")[0], default_timeout=30,
                        timeouts={name: 30 for name in TOOLS})
    journal = Journal(root / "logs/recovery/dev-controls")
    admission = LiveAdmission(root, dev, body, args.slot_owner, args.expected_pawn, args.expected_world,
                              args.expected_endpoint, time.monotonic() + args.deadline_s, journal)
    try:
        admission("preflight")
        backup_info = backup_attestation(backup, root, args.expected_world)
        journal.record("backup_verified", backup=backup_info)
        # Guard the actual nested transport calls as well as each high-level operation.
        for attr in ("client_cmd", "server_debug", "body_call"):
            original = getattr(dev, attr)
            if original is not None:
                def wrapped(*a, _original=original, _attr=attr, **kw):
                    admission("transport:" + _attr)
                    journal.record("transport_intent", transport=_attr, args=a, kwargs=kw)
                    reply = _original(*a, **kw)
                    journal.record("transport_result", transport=_attr, reply=reply)
                    return reply
                setattr(dev, attr, wrapped)
        meta = {"operator": args.slot_owner, "external_watchdog": True, "backup": backup_info,
                "actual_client_build": admission.build, "pid": admission.pid,
                "client_start": admission.started, "bridge_generation": admission.bridge_generation,
                "endpoint": args.expected_endpoint, "world": args.expected_world, "source": attestation}
        result = execute(selected, args.control, dev=dev, game=body, admission=admission, journal=journal, metadata=meta)
        # Owner must explicitly recover referee and verify idle; never release or stop on its behalf.
        try:
            admission("final")
            final = source_attestation(root, Path(args.publication_manifest))
            journal.record("final_source", source=final, matches=final == attestation)
            if final != attestation:
                result["status"] = "blocked_source_changed"
        except Exception as exc:
            journal.record("final_error", error=f"{type(exc).__name__}: {exc}")
            result["status"] = "blocked_final_verification"
        print(json.dumps({"result": result, "journal": str(journal.path)}))
        return 0 if result["status"] == "observed_expected" else 1
    except Exception as exc:
        journal.record("admission_error", error=f"{type(exc).__name__}: {exc}", retain_slot=True)
        raise
    finally:
        journal.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--describe", type=Path, help="validate case file only; no live actions")
    parser.add_argument("--execute", type=Path, help="frozen case file; requires operator admission")
    parser.add_argument("--case", help="case ID")
    parser.add_argument("--control", choices=CONTROLS, default="oracle")
    parser.add_argument("--slot-owner")
    parser.add_argument("--expected-pawn")
    parser.add_argument("--expected-world")
    parser.add_argument("--expected-endpoint")
    parser.add_argument("--backup")
    parser.add_argument("--publication-manifest")
    parser.add_argument("--operator-watchdog", action="store_true", help="operator monitors deadline and retains slot")
    parser.add_argument("--deadline-s", type=int, default=600)
    args = parser.parse_args(argv)
    if bool(args.describe) == bool(args.execute) or not args.case:
        parser.error("pass exactly one of --describe FILE or --execute FILE, plus --case ID")
    if args.execute and (not all((args.slot_owner, args.expected_pawn, args.expected_world, args.expected_endpoint,
                                 args.backup, args.publication_manifest, args.operator_watchdog)) or
                         not 1 <= args.deadline_s <= 1800):
        parser.error("execution requires owner, pawn, world, endpoint, backup, publication manifest and watchdog")
    matches = [c for c in load_cases(args.describe or args.execute) if c.id == args.case]
    if len(matches) != 1:
        parser.error("case ID missing or duplicated")
    try:
        fixtures, steps = prepare(matches[0], args.control)
    except Blocked as exc:
        print(json.dumps({"status": "blocked", "reason": str(exc), "promotion": "disabled"}))
        return 1
    if args.execute:
        try:
            return execute_live(args, matches[0])
        except Blocked as exc:
            print(json.dumps({"status": "blocked", "reason": str(exc), "promotion": "disabled", "retain_slot": True}))
            return 1
    print(json.dumps({"status": "supported_syntax", "fixtures": fixtures, "steps": steps, "promotion": "disabled"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
