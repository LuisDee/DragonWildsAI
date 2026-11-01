r"""Offline replay of the Controller's FIRST call on real chat-ladder requests: a persona or tool-description change is
tried in seconds against recorded situations instead of a ~15 min live ladder run (tools/chat_ladder.py).

The ladder asks for a place in chat ("claude head over to the Water Anima Vent"); the right first answer is go_to
{target: <the place>} (plus a say). Its gate counts model calls per leg, and the waste is a first call that reads
(look / lodestones / situation) before going. This tool:

  extract  harvests the first Controller prompt of each ladder leg's chat- episode (episode_id on the brain log's
           "prompt" rows; review-/situation- episodes are not chat requests) into evals/replay_first_call.jsonl:
           the episode's own non-system messages (command + situation + chat, exactly as sent), the body's position
           then (the episode's last get_state answer before that prompt), the leg's run_id, journey, line, place,
           the expected first tool, and what the live model chose.
  run      re-sends each case's first call, no tool runs: the logged context under TODAY's system prompt and tool
           list, rendered by the live code (Controller.persona() and Controller.tools, with the real client body's
           manifest from client_mod/tests/dump_manifest.lua, wired like brain/run_live.LiveSession), and with the
           context parts derived from his line re-derived by today's code (DERIVED: map_names, Places.mentioned).
           The client is the live Controller one (brain.llm.controller_llm: its effort and max_tokens) for
           DW_CONTROLLER_MODEL or each --model. Pass = the first tool other than say is go_to with a target naming
           the place (every word of the place's name, case-insensitive; or an id the request's own rows give that
           name). --repeat N samples each case N times (per-case pass fraction). Latency p50/p90 per model. Prints the
           planned call count and models, refuses without --yes, and stops at --max-usd.

  .venv\Scripts\python.exe -m tools.replay_first_call extract
  .venv\Scripts\python.exe -m tools.replay_first_call run                       # plan only (5 cases)
  .venv\Scripts\python.exe -m tools.replay_first_call run --limit 20 --yes [--only vent] [--live-misses]
  .venv\Scripts\python.exe -m tools.replay_first_call run --repeat 3 --model anthropic/claude-haiku-5-5,anthropic/claude-sonnet-5-5 --yes

Try a candidate persona without editing brain/persona.md: set DW_PERSONA=<file> (Controller.persona() reads it).
Re-rendered: the system prompt, the tools, and DERIVED context parts. The rest of the context (the situation digest,
chat, body status) is the one the live brain built then: a change to how those are rendered is NOT measured here.
Results: logs/evals/replay_first_call-<ts>.jsonl (each replayed prompt and answer, then one replay_result per sample).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import tempfile
import time
from pathlib import Path

from brain import paths
from brain.controller import SAY_TOOL, Controller, Decision
from brain.jsonl_log import JsonlLogger

ROOT = paths.REPO_ROOT
LADDER = ROOT / "logs" / "evals" / "chat_ladder.jsonl"
CASES = ROOT / "evals" / "replay_first_call.jsonl"
CHAT_EP = "chat-"
DEFAULT_LIMIT = 5


def _rows(path: Path) -> list[dict]:
    """A JSONL file's rows; a torn line (a live run still appending) is skipped."""
    out = []
    try:
        with Path(path).open(encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        out.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        pass
    return out


def sha(obj) -> str:
    text = obj if isinstance(obj, str) else json.dumps(obj, sort_keys=True, ensure_ascii=False)
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:12]


# ------------------------------------------------------------------ scoring


def _norm(s) -> str:
    return " ".join(re.sub(r"[^\w']+", " ", str(s or "")).lower().split())


FILLER = {"the", "a", "an", "by", "of", "at", "to", "near"}


def _words(s) -> set[str]:
    return {re.sub(r"'s$", "", w) for w in _norm(s).split()} - FILLER


def names_place(target, place) -> bool:
    """Every word of the place's name (articles aside) is in the target, case-insensitive: "Water Anima Vent" and
    "Temple Woods entrance" name "the Water Anima Vent" / "the temple entrance"; "Anima Vent" does not name "the
    Earth Anima Vent" (a plain substring-either-way match passed it: replay run 1, a vent 16 m off, unnamed)."""
    t, p = _words(target), _words(place)
    return bool(t and p) and p <= t


def named_ids(messages: list[dict] | None) -> dict[str, list[str]]:
    """id -> the names the request itself gives it: {"name", "id"} objects (references, look rows) and situation
    entries written "Name (16 m, id X, ...)". A go_to by id then names the place when one of those names does."""
    out: dict[str, list[str]] = {}

    def walk(v):
        if isinstance(v, dict):
            if isinstance(v.get("id"), str) and isinstance(v.get("name"), str):
                out.setdefault(v["id"], []).append(v["name"])
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str):
            for m in re.finditer(r"([^;:|()\[\]]+)\(([^()]*)\)", v):
                for i in re.findall(r"\bid ([^\s,;)]+)", m.group(2)):
                    out.setdefault(i, []).append(m.group(1).strip())

    for m in messages or []:
        if m.get("role") == "user" and isinstance(m.get("content"), str):
            try:
                walk(json.loads(m["content"]))
            except json.JSONDecodeError:
                walk(m["content"])
    return out


def score(place: str, calls: list[dict], messages: list[dict] | None = None) -> dict:
    """``calls``: the response's tool calls ({name, arguments}). say is speech, not a step: the first other call
    must be go_to naming the place (by name, or by an id the request's own rows name it). ``one_call``: a go_to to
    the place anywhere in the reply (reads beside an action are not run, so that leg still went on its first call)."""
    ids = named_ids(messages)

    def goes(c) -> bool:
        t = (c.get("arguments") or {}).get("target") if c.get("name") == "go_to" else None
        return names_place(t, place) or any(names_place(n, place) for n in ids.get(str(t), []))

    acts = [c for c in calls if c.get("name") != SAY_TOOL]
    first = acts[0] if acts else None
    target = (first.get("arguments") or {}).get("target") if first else None
    return {"passed": bool(first) and goes(first), "one_call": any(goes(c) for c in acts),
            "first": first.get("name") if first else None,
            "target": target if isinstance(target, (str, type(None))) else json.dumps(target),
            "tools": [c.get("name") for c in calls]}


# ------------------------------------------------------------------ extract


def _episode(rows: list[dict], ep: str) -> tuple[dict | None, dict | None, dict | None]:
    """The episode's first Controller prompt row (it carries the full request), the answer to it, and the body state
    the Controller was given: the last get_state answer before that prompt (bridge_send/recv rows, matched by id)."""
    prompt, state, asked = None, None, set()
    for r in rows:
        msg = r.get("msg") if isinstance(r.get("msg"), dict) else {}
        if prompt is None and r.get("kind") == "bridge_send" and msg.get("tool") == "get_state":
            asked.add(msg.get("id"))
        elif prompt is None and r.get("kind") == "bridge_recv" and msg.get("id") in asked and msg.get("ok"):
            state = msg.get("data") if isinstance(msg.get("data"), dict) else state
        if r.get("episode_id") != ep or r.get("component") != "controller":
            continue
        if prompt is None and r.get("kind") == "prompt":
            prompt = r
        elif prompt is not None and r.get("kind") == "llm_response":
            return prompt, r, state
    return prompt, None, state


def _command(messages: list[dict]) -> dict:
    for m in messages:
        if m.get("role") == "user" and isinstance(m.get("content"), str):
            try:
                cmd = json.loads(m["content"]).get("command")
            except (json.JSONDecodeError, AttributeError):
                continue
            if isinstance(cmd, dict):
                return cmd
    return {}


def extract(ladder: Path = LADDER, log_dir: Path | None = None) -> tuple[list[dict], dict]:
    log_dir = Path(log_dir) if log_dir else paths.log_dir()
    cache: dict[str, list[dict]] = {}
    cases, seen = [], set()
    why = {"no_chat_episode": 0, "no_brain_log": 0, "no_prompt": 0, "partial_prompt": 0, "line_mismatch": 0,
           "duplicate": 0, "director": 0}
    for row in _rows(ladder):
        eps = [e for e in (row.get("calls_by_episode") or {}) if e.startswith(CHAT_EP)]
        if not eps or not row.get("place"):
            why["no_chat_episode"] += 1
            continue
        name = row.get("brain_log")
        if name not in cache:
            cache[name] = _rows(log_dir / name) if name else []
        rows = cache[name]
        if not rows:
            why["no_brain_log"] += 1
            continue
        start = next((r for r in rows if r.get("kind") == "session_start"), {})
        for ep in eps[:1]:  # the leg's request (a leg is one chat line)
            key = (name, ep)
            prompt, answer, state = _episode(rows, ep)
            if prompt is None:
                why["no_prompt"] += 1
                continue
            if prompt.get("messages_from") or not prompt.get("tools") or not prompt.get("messages"):
                why["partial_prompt"] += 1  # a continuation row: only the added messages were logged
                continue
            msgs = [m for m in prompt["messages"] if m.get("role") != "system"]
            cmd = _command(msgs)
            if _norm(cmd.get("text")) != _norm(row.get("line")):
                why["line_mismatch"] += 1
                continue
            if start.get("director"):
                why["director"] += 1  # the replay wires no Director (no ladder run had one)
                continue
            if key in seen or sha(msgs) in seen:
                why["duplicate"] += 1
                continue
            seen.update({key, sha(msgs)})
            system = next((m.get("content") for m in prompt["messages"] if m.get("role") == "system"), "")
            live = score(row["place"], (answer or {}).get("tool_calls") or [], msgs)
            cases.append({
                "id": f"{row.get('run_id')}/{ep}", "run_id": row.get("run_id"), "journey": row.get("journey"),
                "line": row.get("line"), "place": row["place"], "expected": {"tool": "go_to", "target": row["place"]},
                "brain_log": name, "episode_id": ep, "ts": prompt.get("ts"),
                "player": start.get("player") or cmd.get("player"), "name": start.get("name") or "Claude",
                "companion_sha": start.get("companion_sha"), "dirty": start.get("dirty"),
                "logged": {"model": prompt.get("model"), "effort": prompt.get("effort"), "settings": prompt.get("settings"),
                           "system_sha": sha(system), "tools_sha": sha(prompt["tools"]),
                           "tools": [(t.get("function") or {}).get("name") for t in prompt["tools"]]},
                "live": {**live, "calls": row.get("calls_by_episode", {}).get(ep)},
                "state": {"position": (state or {}).get("position")},  # what DERIVED parts read
                "messages": msgs,
            })
    return cases, why


def write_cases(cases: list[dict], out: Path = CASES) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8", newline="\n") as f:
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    os.replace(tmp, out)


# ------------------------------------------------------------------ today's prompt


def body_caps():
    """The real client body's capabilities answer, offline (the Lua modules, no game), through brain discover()."""
    from brain.capabilities import discover
    from evals.manifest_eval import CapsClient, real_manifest
    return discover(CapsClient(real_manifest()))


def live_controller(llm, player: str, workdir: Path, logger: JsonlLogger, caps=None, name: str = "Claude") -> Controller:
    """A Controller wired like brain/run_live.LiveSession (manifest, skills, knowledge, map names; no Director)."""
    from brain.knowledge import open_knowledge
    from brain.skill_library import SkillLibrary
    from brain.state_store import StateStore
    caps = caps if caps is not None else body_caps()
    ctl = Controller(llm, None, StateStore(workdir / "state", caps.registry()), logger, name=name, player=player,
                     available_tools=caps.tools, skills=SkillLibrary(workdir / "skills"), caps=caps,
                     knowledge=open_knowledge())
    try:  # LiveSession: the game's map data, when the data file is there
        from brain.places import Places
        ctl.places = Places()
        ctl.use_map_names()
    except Exception:
        pass
    return ctl


# Context parts the Controller derives from his line (and the state) in Controller.context, re-derived by today's code.
# Each: (key, fn(ctl, text, state) -> value or None). AFTER: keys Controller.context adds after them (the key order is
# kept, so a re-derived context is byte-equal to the live one when nothing changed).
def _map_names(ctl: Controller, text: str, state: dict):
    """Controller.context: map names said in his line (094a27d), via the same Places.mentioned call."""
    if not text or getattr(ctl, "places", None) is None:
        return None
    try:
        return ctl.places.mentioned(text, (state or {}).get("position")) or None
    except Exception:  # context is best effort there too
        return None


DERIVED = (("map_names", _map_names),)
AFTER = ("chat",)


def derived_messages(ctl: Controller, case: dict) -> list[dict]:
    """The case's messages with DERIVED context parts recomputed from the logged command text + state position."""
    out = []
    for m in case["messages"]:
        m = dict(m)
        try:
            ctx = json.loads(m["content"]) if m.get("role") == "user" and isinstance(m.get("content"), str) else None
        except json.JSONDecodeError:
            ctx = None
        if isinstance(ctx, dict) and isinstance(ctx.get("command"), dict):
            text = ctx["command"].get("text") or ""
            ctx = {k: v for k, v in ctx.items() if k not in dict(DERIVED)}
            tail = {k: ctx.pop(k) for k in [k for k in ctx if k in AFTER]}
            for key, fn in DERIVED:
                value = fn(ctl, text, case.get("state") or {})
                if value not in (None, [], {}, ""):
                    ctx[key] = value
            ctx.update(tail)
            m["content"] = json.dumps(ctx, default=str, ensure_ascii=False)  # as Controller.decide dumps it
        out.append(m)
    return out


def render(ctl: Controller, case: dict) -> list[dict]:
    """The case's first request as today's code would send it: today's system prompt, the episode's own messages
    with today's DERIVED context parts."""
    return [{"role": "system", "content": ctl.persona()}] + derived_messages(ctl, case)


def same_as_logged(ctl: Controller, case: dict) -> bool:
    lg = case.get("logged") or {}
    return lg.get("system_sha") == sha(ctl.persona()) and lg.get("tools_sha") == sha(ctl.tools)


def first_call(ctl: Controller, case: dict, messages: list[dict] | None = None):
    """One model call, at the effort Controller.decide gives a player's line to him (body_event None)."""
    d = Decision()
    cmd = _command(case["messages"])
    if cmd.get("addressed", True) and (cmd.get("text") or "").strip():
        d.effort = ctl.addressed_effort
    return ctl._complete(messages or render(ctl, case), ctl.tools, d, step=0)


def replay(cases: list[dict], make_controller, repeat: int = 1, clock=time.monotonic, stop=None) -> list[dict]:
    """``make_controller(player, name)`` -> Controller (one per player; its llm makes the calls). One row per sample;
    ``stop(row)`` -> True ends the run after that sample (the spend cap)."""
    ctls: dict[tuple, Controller] = {}
    results = []
    for c in cases:
        key = (c.get("player") or "Luis", c.get("name") or "Claude")
        if key not in ctls:
            ctls[key] = make_controller(*key)
        ctl = ctls[key]
        msgs = render(ctl, c)
        context_changed = msgs[1:] != c["messages"]
        for i in range(max(1, repeat)):
            t0 = clock()
            try:
                resp = first_call(ctl, c, msgs)
                calls = [{"name": t.name, "arguments": t.arguments} for t in resp.tool_calls]
                res = {**score(c["place"], calls, c["messages"]), "calls": calls, "content": resp.content,
                       "usage": resp.usage}
            except Exception as exc:  # one failed call is a miss, not the end of the run
                res = {"passed": False, "one_call": False, "first": None, "target": None, "tools": [], "error": repr(exc)}
            row = {"id": c["id"], "line": c["line"], "place": c["place"], "model": getattr(ctl.llm, "model", None),
                   "sample": i, "latency_s": round(clock() - t0, 2), "same_prompt_as_live": same_as_logged(ctl, c),
                   "context_changed": context_changed, "live": c.get("live"), **res}
            results.append(row)
            if stop is not None and stop(row):
                return results
    return results


def _pct(xs: list[float], q: float) -> float | None:
    """Nearest-rank percentile."""
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    return xs[max(0, min(len(xs) - 1, math.ceil(q * len(xs)) - 1))] if xs else None


def summarize(results: list[dict]) -> dict:
    """Per model: samples, passes, latency p50/p90; per case and model: the pass fraction and the tools chosen. With
    two or more models, each case the FIRST model misses (most of its samples) is "decision" when another model
    passes it (most samples) and "prompt" when they all miss it."""
    models = list(dict.fromkeys(r.get("model") for r in results))
    per_model = {}
    for m in models:
        rs = [r for r in results if r.get("model") == m]
        lat = [r["latency_s"] for r in rs if not r.get("error")]
        per_model[m] = {"samples": len(rs), "passed": sum(r["passed"] for r in rs),
                        "one_call": sum(r["one_call"] for r in rs), "p50_s": _pct(lat, 0.5), "p90_s": _pct(lat, 0.9)}
    cases: dict[str, dict] = {}
    for r in results:
        c = cases.setdefault(r["id"], {"id": r["id"], "place": r["place"], "live": (r.get("live") or {}).get("tools"),
                                       "context_changed": r.get("context_changed"), "models": {}})
        mm = c["models"].setdefault(r.get("model"), {"n": 0, "passed": 0, "chose": []})
        mm["n"] += 1
        mm["passed"] += bool(r["passed"])
        mm["chose"].append(r.get("first") or ("error" if r.get("error") else "no tool"))
    split: dict[str, list[str]] = {"decision": [], "prompt": []}
    if len(models) > 1:
        base, others = models[0], models[1:]
        for c in cases.values():
            got = {m: c["models"].get(m) for m in models}
            if not got[base] or got[base]["passed"] * 2 > got[base]["n"]:
                continue
            ok = [m for m in others if got[m] and got[m]["passed"] * 2 > got[m]["n"]]
            split["decision" if ok else "prompt"].append(c["id"])
    return {"models": per_model, "cases": list(cases.values()), "split": split}


# ------------------------------------------------------------------ commands


def select(cases: list[dict], only: str | None, live_misses: bool, limit: int) -> list[dict]:
    if only:
        keys = [k.strip().lower() for k in only.split(",") if k.strip()]
        cases = [c for c in cases if any(k in f"{c['id']} {c.get('journey')} {c['line']}".lower() for k in keys)]
    if live_misses:
        cases = [c for c in cases if not (c.get("live") or {}).get("passed")]
    return cases[:limit] if limit > 0 else cases


def cmd_extract(a) -> int:
    cases, why = extract(Path(a.ladder), Path(a.log_dir) if a.log_dir else None)
    write_cases(cases, Path(a.out))
    live = sum((c.get("live") or {}).get("passed", False) for c in cases)
    print(f"{len(cases)} cases -> {a.out}  (live first call passed {live}/{len(cases)}; "
          f"{sum(bool((c.get('state') or {}).get('position')) for c in cases)} with the body's position)")
    print("skipped: " + (", ".join(f"{k} {v}" for k, v in why.items() if v) or "none"))
    try:
        with tempfile.TemporaryDirectory() as tmp:
            caps = body_caps()
            players = {c.get("player") or "Luis" for c in cases}
            ctls = {p: live_controller(None, p, Path(tmp) / p, JsonlLogger(Path(tmp) / "x.jsonl"), caps) for p in players}
            same = sum(same_as_logged(ctls[c.get("player") or "Luis"], c) for c in cases)
            changed = sum(derived_messages(ctls[c.get("player") or "Luis"], c) != c["messages"] for c in cases)
        print(f"{same}/{len(cases)} were sent with exactly today's system prompt + tools; "
              f"today's derived context ({', '.join(k for k, _ in DERIVED)}) differs in {changed}/{len(cases)}")
    except (Exception, SystemExit) as exc:  # no Lua here: the cases are still written
        print(f"(could not render today's prompt to compare: {exc!r})")
    return 0


def client_for(model: str):
    """The live Controller client (brain.llm.controller_llm: its effort and max_tokens) for ``model``."""
    from brain.llm import CONTROLLER_MODEL_ENV, controller_llm
    saved = os.environ.get(CONTROLLER_MODEL_ENV)
    os.environ[CONTROLLER_MODEL_ENV] = model
    try:
        return controller_llm()
    finally:
        if saved is None:
            os.environ.pop(CONTROLLER_MODEL_ENV, None)
        else:
            os.environ[CONTROLLER_MODEL_ENV] = saved


def cmd_run(a) -> int:
    from brain.llm import CONTROLLER_MODEL_ENV, missing_keys
    from tools import spend
    cases = select(_rows(Path(a.cases)), a.only, a.live_misses, a.limit)
    models = [m.strip() for m in (a.model or os.environ.get(CONTROLLER_MODEL_ENV) or "").split(",") if m.strip()]
    repeat = max(1, a.repeat)
    print(f"[replay_first_call] {len(cases)} cases x {repeat} samples x {len(models)} model(s) "
          f"({', '.join(models) or f'<unset {CONTROLLER_MODEL_ENV}>'}) = planned calls: "
          f"{len(cases) * repeat * len(models)} (no tools run); stops at ${a.max_usd:.2f}")
    if not cases:
        print("no cases: run `extract` first (or loosen --only/--live-misses)")
        return 2
    if not models:
        print(f"Refusing: set {CONTROLLER_MODEL_ENV} or pass --model.")
        return 2
    for m in models:
        keys = missing_keys(m)
        if keys:
            print(f"Refusing: API key for {m} not set (missing {keys}).")
            return 2
    if not a.yes:
        print("Refusing: pass --yes to confirm the API calls above.")
        return 2
    log = JsonlLogger(paths.log_dir() / "evals" / f"replay_first_call-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
    prices = spend.load_prices()
    spent = [0.0]

    def stop(row: dict) -> bool:
        spent[0] += spend.price(row.get("model"), row.get("usage") or {}, prices)[0]
        log.log("replay_result", usd_so_far=round(spent[0], 5), **row)
        return spent[0] >= a.max_usd

    caps = body_caps()
    results: list[dict] = []
    with tempfile.TemporaryDirectory() as tmp:
        for m in models:
            llm = client_for(m)
            work = Path(tmp) / re.sub(r"\W+", "_", m)
            results += replay(cases, lambda player, name: live_controller(llm, player, work / player, log, caps, name),
                              repeat, stop=stop)
            if spent[0] >= a.max_usd:
                print(f"STOPPED: spend cap ${a.max_usd:.2f} reached")
                break
    s = summarize(results)
    short = {m: str(m).split("/")[-1] for m in s["models"]}
    print("per case (pass fraction, first tool of each sample):")
    for c in s["cases"]:
        cols = "; ".join(f"{short[m]} {v['passed']}/{v['n']} [{', '.join(v['chose'])}]" for m, v in c["models"].items())
        print(f"  {c['id']} {c['place']!r}: {cols}  (live: {c['live']})")
    for m, v in s["models"].items():
        lat = lambda x: f"{x:.2f}s" if x is not None else "-"  # noqa: E731
        print(f"[{short[m]}] pass rate {v['passed']}/{v['samples']}; go_to to the place in the first reply "
              f"{v['one_call']}/{v['samples']}; latency p50 {lat(v['p50_s'])} p90 {lat(v['p90_s'])}")
    firsts = [r for r in results if r["sample"] == 0 and r.get("model") == next(iter(s["models"]), None)]
    print(f"{sum(r['same_prompt_as_live'] for r in firsts)}/{len(firsts)} cases replayed with the system+tools live had; "
          f"derived context ({', '.join(k for k, _ in DERIVED)}) changed in {sum(r['context_changed'] for r in firsts)}"
          f"/{len(firsts)}; ${spent[0]:.4f}")
    if len(s["models"]) > 1:
        base = short[next(iter(s["models"]))]
        print(f"{base} misses (most samples): decision-making (another model passes) {len(s['split']['decision'])}: "
              f"{s['split']['decision']}; prompt-driven (all miss) {len(s['split']['prompt'])}: {s['split']['prompt']}")
    print(f"results: {log.path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract")
    e.add_argument("--ladder", default=str(LADDER))
    e.add_argument("--log-dir", default=None, help="where the ladder rows' brain_log files are (default logs/)")
    e.add_argument("--out", default=str(CASES))
    r = sub.add_parser("run")
    r.add_argument("--cases", default=str(CASES))
    r.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"first N cases (default {DEFAULT_LIMIT}; 0 = all)")
    r.add_argument("--only", help="comma-separated substrings of the case id, journey or line")
    r.add_argument("--live-misses", action="store_true", help="only cases whose live first call missed")
    r.add_argument("--repeat", type=int, default=1, help="samples per case (no sampling params: each is a fresh draw)")
    r.add_argument("--model", help="comma-separated LiteLLM model strings (default DW_CONTROLLER_MODEL)")
    r.add_argument("--max-usd", type=float, default=0.50, help="stop once the run has spent this much (default 0.50)")
    r.add_argument("--yes", action="store_true", help="confirm you accept the API spend")
    a = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return {"extract": cmd_extract, "run": cmd_run}[a.cmd](a)


if __name__ == "__main__":
    raise SystemExit(main())
