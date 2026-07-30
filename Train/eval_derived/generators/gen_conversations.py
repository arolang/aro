#!/usr/bin/env python3
"""Multi-turn conversation traces for the interactive `aro ask` REPL.

`aro ask` is a chat: the user issues a request, the model emits ARO, then the
user asks for a change ("add validation", "now emit an event", "filter it"), and
the model must refine the SAME application across turns. All existing training
data is single-turn, so the model never learns to carry context or apply an
incremental edit. This generator builds validated multi-turn conversations
(`{messages: [system, user, assistant, user, assistant, …]}`) where each user
turn requests a change and each assistant turn returns the cumulatively-updated,
`aro check`-valid feature set. A conversation is emitted only if every assistant
turn passes `aro check`.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "conversations.jsonl"

try:
    SYSTEM = config.build_system_prompt()
except Exception:
    SYSTEM = ("You are an expert ARO developer. ARO is a DSL where every statement is "
              "`Verb the <Result> preposition [the] <Object>.` inside a feature set "
              "`(Name: Business Activity) { … }` that ends in Return or Throw. Emit only "
              "valid ARO in ```aro fenced blocks.")


def cap(s):
    return s[0].upper() + s[1:]


# ── conversation arcs: each returns a list of (user_text, aro_code) turns ─────
# Each assistant turn is a COMPLETE feature set reflecting all changes so far, so
# the model learns to re-emit the whole updated set after each incremental edit.

def arc_crud(e, f):
    E = cap(e)
    list_fs = (f"(list{E}s: {E} API) {{\n"
               f"    Retrieve the <{e}s> from the <{e}-repository>.\n"
               f"    Return an <OK: status> with <{e}s>.\n"
               f"}}")
    get_fs = (f"(get{E}: {E} API) {{\n"
              f"    Extract the <id> from the <pathParameters: id>.\n"
              f"    Retrieve the <{e}> from the <{e}-repository> where <id> = <id>.\n"
              f"    Return an <OK: status> with <{e}>.\n"
              f"}}")
    create_fs = (f"(create{E}: {E} API) {{\n"
                 f"    Extract the <data> from the <request: body>.\n"
                 f"    Create the <{e}> with <data>.\n"
                 f"    Store the <{e}> into the <{e}-repository>.\n"
                 f"    Return a <Created: status> with <{e}>.\n"
                 f"}}")
    create_guarded = (f"(create{E}: {E} API) {{\n"
                      f"    Extract the <data> from the <request: body>.\n"
                      f"    Extract the <{f}> from the <data: {f}>.\n"
                      f"    Throw a <BadRequest: status> for the <{e}> when <{f}> == \"\".\n"
                      f"    Create the <{e}> with <data>.\n"
                      f"    Store the <{e}> into the <{e}-repository>.\n"
                      f"    Return a <Created: status> with <{e}>.\n"
                      f"}}")
    create_event = (f"(create{E}: {E} API) {{\n"
                    f"    Extract the <data> from the <request: body>.\n"
                    f"    Extract the <{f}> from the <data: {f}>.\n"
                    f"    Throw a <BadRequest: status> for the <{e}> when <{f}> == \"\".\n"
                    f"    Create the <{e}> with <data>.\n"
                    f"    Store the <{e}> into the <{e}-repository>.\n"
                    f"    Emit a <{E}Created: event> with <{e}>.\n"
                    f"    Return a <Created: status> with <{e}>.\n"
                    f"}}")
    return [
        (f"Write an ARO feature set named list{E}s that returns all {e}s from the {e}-repository.", list_fs),
        (f"Add a get{E} handler that fetches one {e} by id from the path parameters.", get_fs),
        (f"Now add create{E}: extract the request body, store a new {e}, and return Created.", create_fs),
        (f"In create{E}, reject the request with a BadRequest when the {f} is empty.", create_guarded),
        (f"After storing, emit a {E}Created event with the {e}.", create_event),
    ]


def arc_pipeline(e, f):
    E = cap(e)
    base = (f"(Active{E}s: {E} API) {{\n"
            f"    Retrieve the <{e}s> from the <{e}-repository>.\n"
            f"    Return an <OK: status> with <{e}s>.\n"
            f"}}")
    filtered = (f"(Active{E}s: {E} API) {{\n"
                f"    Retrieve the <{e}s> from the <{e}-repository>.\n"
                f"    Filter the <active> from the <{e}s> where <status> = \"active\".\n"
                f"    Return an <OK: status> with <active>.\n"
                f"}}")
    counted = (f"(Active{E}s: {E} API) {{\n"
               f"    Retrieve the <{e}s> from the <{e}-repository>.\n"
               f"    Filter the <active> from the <{e}s> where <status> = \"active\".\n"
               f"    Reduce the <total: count> from the <active>.\n"
               f"    Return an <OK: status> with <total>.\n"
               f"}}")
    return [
        (f"Write an ARO feature set that retrieves {e}s and returns them.", base),
        (f"Filter it to only the {e}s whose status is active.", filtered),
        (f"Count the active {e}s with Reduce and return the count instead of the list.", counted),
    ]


def arc_config(e, f):
    E = cap(e)
    read_fs = (f"(Load{E}: Setup) {{\n"
               f"    Read the <{e}-config> from the <file: \"{e}.json\">.\n"
               f"    Log <{e}-config> to the <console>.\n"
               f"    Return an <OK: status> for the <startup>.\n"
               f"}}")
    extract_fs = (f"(Load{E}: Setup) {{\n"
                  f"    Read the <{e}-config> from the <file: \"{e}.json\">.\n"
                  f"    Extract the <{f}> from the <{e}-config: {f}>.\n"
                  f"    Log <{f}> to the <console>.\n"
                  f"    Return an <OK: status> for the <startup>.\n"
                  f"}}")
    return_fs = (f"(Load{E}: Setup) {{\n"
                 f"    Read the <{e}-config> from the <file: \"{e}.json\">.\n"
                 f"    Extract the <{f}> from the <{e}-config: {f}>.\n"
                 f"    Return an <OK: status> with <{f}>.\n"
                 f"}}")
    return [
        (f"Write an ARO feature set that reads {e}.json and logs its contents.", read_fs),
        (f"Also extract the {f} field from the config.", extract_fs),
        (f"Return the {f} as an OK status instead of logging it.", return_fs),
    ]


ARCS = [arc_crud, arc_pipeline, arc_config]
ENTS = [("user", "email"), ("order", "total"), ("product", "name"),
        ("invoice", "amount"), ("ticket", "subject"), ("account", "status"),
        ("booking", "date"), ("review", "rating")]


def main():
    rows, seen = [], set()
    convos = turns_checked = turns_passed = 0
    dropped = 0
    aro_missing = False
    for arc in ARCS:
        for e, f in ENTS:
            turns = arc(e, f)
            messages = [{"role": "system", "content": SYSTEM}]
            ok_all = True
            for user_text, aro in turns:
                turns_checked += 1
                res, err = config.aro_check_snippet(aro, timeout=15)
                if res is None:
                    aro_missing = True; ok_all = False; break
                if not res:
                    line = err.splitlines()[1].strip()[:60] if err and len(err.splitlines()) > 1 else str(err)[:60]
                    print(f"  DROP {arc.__name__}/{e}: turn failed aro check: {line}")
                    ok_all = False; break
                turns_passed += 1
                messages.append({"role": "user", "content": user_text})
                messages.append({"role": "assistant", "content": f"```aro\n{aro}\n```"})
            if not ok_all:
                dropped += 1
                continue
            key = arc.__name__ + "|" + e
            if key in seen:
                continue
            seen.add(key)
            rows.append({
                "messages": messages,
                "task_type": "conversation",
                "n_turns": len(turns),
                "source": "eval_conversations",
            })
            convos += 1
    OUT.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate.")
    print(f"conversations: {convos} multi-turn traces "
          f"({turns_passed}/{turns_checked} assistant turns passed aro check, "
          f"{dropped} conversations dropped) -> {OUT.name}")


if __name__ == "__main__":
    main()
