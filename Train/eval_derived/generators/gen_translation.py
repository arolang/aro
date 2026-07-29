#!/usr/bin/env python3
"""Validated source→ARO translation pairs (issue #438).

translation showed 100% syntax-pass but ~75% hallucination and semantic_score
≈ 0: the model emits well-formed ARO that does not preserve the source's
meaning. These pairs are built so meaning is preserved *by construction* — each
scenario knows both the source behaviour and the ARO verbs that realise it — and
every ARO output is validated two ways:

  1. `aro check` passes (syntactic), and
  2. the ARO contains every verb in the scenario's intent set (semantic /
     verb-intent match, not just aro check).

Each pair carries a `<think>` trace mapping each source statement to its ARO
action, so the model learns to translate by intent rather than by surface form.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/kris/Projects/ARO/ARO-Lang")
sys.path.insert(0, str(REPO / "Train" / "script"))
import config  # noqa: E402

OUT = REPO / "Train" / "eval_derived" / "translation.jsonl"

_VERB_RE = re.compile(r'^\s*([A-Z][A-Za-z]+)\b', re.M)


def verbs_in(aro):
    body = re.sub(r'\(\*.*?\*\)', '', aro, flags=re.DOTALL)
    return {v.lower() for v in _VERB_RE.findall(body)}


# ── scenario families ───────────────────────────────────────────────────────
# Each returns (lang, source, aro, think, intent_verbs). Parameterised to give
# volume while keeping meaning fixed. `intent_verbs` is the semantic contract:
# the ARO must contain every one of these verbs.

def fam_read_process_return(name, path, field):
    lang = "python"
    src = (f"def load_{name}():\n"
           f"    data = open(\"{path}\").read()\n"
           f"    record = parse(data)\n"
           f"    return record[\"{field}\"]")
    aro = (f"(Load{name.capitalize()}: {name} API) {{\n"
           f"    Read the <data> from the <file: \"{path}\">.\n"
           f"    Extract the <record> from the <data>.\n"
           f"    Extract the <{field}> from the <record: {field}>.\n"
           f"    Return an <OK: status> with <{field}>.\n"
           f"}}")
    think = (f"The Python opens and reads a file → ARO `Read ... from the <file>`. "
             f"`parse(data)` extracts a record → `Extract the <record>`. Returning "
             f"`record['{field}']` becomes `Extract the <{field}> from the <record: {field}>` "
             f"then `Return an <OK: status> with <{field}>`.")
    return lang, src, aro, think, {"read", "extract", "return"}


def fam_fetch_transform_return(name, url):
    lang = "javascript"
    src = (f"async function get{name.capitalize()}() {{\n"
           f"  const res = await fetch(\"{url}\");\n"
           f"  const json = await res.json();\n"
           f"  return transform(json);\n"
           f"}}")
    aro = (f"(Get{name.capitalize()}: {name} API) {{\n"
           f"    Fetch the <response> from the <url: \"{url}\">.\n"
           f"    Extract the <payload> from the <response: body>.\n"
           f"    Transform the <result> from the <payload>.\n"
           f"    Return an <OK: status> with <result>.\n"
           f"}}")
    think = (f"`fetch(url)` is an external request → ARO REQUEST verb `Fetch ... from the <url>`. "
             f"`res.json()` reads the body → `Extract the <payload> from the <response: body>`. "
             f"`transform(json)` is an internal OWN transform → `Transform the <result>`. "
             f"The JS return becomes `Return an <OK: status> with <result>`.")
    return lang, src, aro, think, {"fetch", "extract", "transform", "return"}


def fam_filter_return(name, field, value):
    lang = "python"
    src = (f"def by_{field}({name}):\n"
           f"    return [x for x in {name} if x[\"{field}\"] == \"{value}\"]")
    aro = (f"(Filter{name.capitalize()}: {name} API) {{\n"
           f"    Retrieve the <items> from the <{name}-repository>.\n"
           f"    Filter the <filtered> from the <items> where <{field}> = \"{value}\".\n"
           f"    Return an <OK: status> with <filtered>.\n"
           f"}}")
    think = (f"The list comprehension keeps items where `{field} == \"{value}\"` → ARO "
             f"`Filter ... where <{field}> = \"{value}\"`. The items come from the repository → "
             f"`Retrieve the <items>`. Returning the filtered list → `Return an <OK: status> with <filtered>`.")
    return lang, src, aro, think, {"retrieve", "filter", "return"}


def fam_create_emit(name, field):
    lang = "javascript"
    src = (f"function create{name.capitalize()}(req) {{\n"
           f"  const data = req.body;\n"
           f"  const {name} = save(data);\n"
           f"  emit(\"{name.capitalize()}Created\", {name});\n"
           f"  return {{ status: 201, body: {name} }};\n"
           f"}}")
    aro = (f"(create{name.capitalize()}: {name} API) {{\n"
           f"    Extract the <data> from the <request: body>.\n"
           f"    Create the <{name}> with <data>.\n"
           f"    Store the <{name}> into the <{name}-repository>.\n"
           f"    Emit a <{name.capitalize()}Created: event> with <{name}>.\n"
           f"    Return a <Created: status> with <{name}>.\n"
           f"}}")
    think = (f"`req.body` → `Extract the <data> from the <request: body>`. `save(data)` both "
             f"creates and persists → `Create the <{name}>` + `Store the <{name}> in the "
             f"<{name}-repository>`. `emit(...)` → `Emit a <{name.capitalize()}Created: event>`. "
             f"HTTP 201 → `Return a <Created: status>`.")
    return lang, src, aro, think, {"extract", "create", "store", "emit", "return"}


def fam_hash_store(entity):
    lang = "python"
    src = (f"def register({entity}):\n"
           f"    pw = hashlib.sha256({entity}[\"password\"].encode()).hexdigest()\n"
           f"    {entity}[\"password\"] = pw\n"
           f"    db.save({entity})")
    aro = (f"(register{entity.capitalize()}: {entity} API) {{\n"
           f"    Extract the <{entity}> from the <request: body>.\n"
           f"    Extract the <password> from the <{entity}: password>.\n"
           f"    Compute the <digest: hash> from <password>.\n"
           f"    Create the <secured-{entity}> with {{ password: <digest> }}.\n"
           f"    Store the <secured-{entity}> into the <{entity}-repository>.\n"
           f"    Return an <OK: status> with <secured-{entity}>.\n"
           f"}}")
    think = (f"`hashlib.sha256(...).hexdigest()` hashes the password → ARO `Compute the <digest: hash> "
             f"from <password>`. Reassigning the field is immutable in ARO, so build a new record with "
             f"`Create the <secured-{entity}> with {{ password: <digest> }}`. `db.save` → `Store ... into "
             f"the <{entity}-repository>`.")
    return lang, src, aro, think, {"extract", "compute", "create", "store", "return"}


def fam_iterate_log(name, coll):
    lang = "go"
    src = (f"func process({coll} []Item) {{\n"
           f"    for _, item := range {coll} {{\n"
           f"        log.Println(item)\n"
           f"    }}\n"
           f"}}")
    aro = (f"(Process{name.capitalize()}: {name} API) {{\n"
           f"    Retrieve the <{coll}> from the <{name}-repository>.\n"
           f"    For each <item> in <{coll}> {{\n"
           f"        Log <item> to the <console>.\n"
           f"    }}\n"
           f"    Return an <OK: status> for the <{name}>.\n"
           f"}}")
    think = (f"The Go `for range` loop iterates the slice → ARO `For each <item> in <{coll}>`. "
             f"`log.Println(item)` → `Log <item> to the <console>`. The slice comes from the "
             f"repository → `Retrieve the <{coll}>`.")
    return lang, src, aro, think, {"retrieve", "log", "return"}


def fam_compute_return(name, a, b, op):
    lang = "javascript"
    src = (f"function {name}(a, b) {{\n"
           f"  return a {op} b;\n"
           f"}}")
    aro = (f"({name.capitalize()}: math API) {{\n"
           f"    Extract the <a> from the <request: a>.\n"
           f"    Extract the <b> from the <request: b>.\n"
           f"    Compute the <result> from <a> {op} <b>.\n"
           f"    Return an <OK: status> with <result>.\n"
           f"}}")
    think = (f"The function returns `a {op} b` → ARO arithmetic `Compute the <result> from <a> {op} <b>`. "
             f"The two operands are inputs → `Extract the <a>` / `Extract the <b>`. The return → "
             f"`Return an <OK: status> with <result>`.")
    return lang, src, aro, think, {"extract", "compute", "return"}


def fam_validate_throw(name, field):
    lang = "python"
    src = (f"def submit({name}):\n"
           f"    if not {name}[\"{field}\"]:\n"
           f"        raise ValueError(\"{field} required\")\n"
           f"    return save({name})")
    aro = (f"(submit{name.capitalize()}: {name} API) {{\n"
           f"    Extract the <{name}> from the <request: body>.\n"
           f"    Extract the <{field}> from the <{name}: {field}>.\n"
           f"    Throw a <BadRequest: status> for the <{name}> when <{field}> == \"\".\n"
           f"    Store the <{name}> into the <{name}-repository>.\n"
           f"    Return an <OK: status> with <{name}>.\n"
           f"}}")
    think = (f"The `if not ...: raise` guard maps to an ARO `Throw ... when <{field}> == \"\"` guard. "
             f"`save({name})` → `Store the <{name}> into the <{name}-repository>`. The happy-case return → "
             f"`Return an <OK: status>`.")
    return lang, src, aro, think, {"extract", "throw", "store", "return"}


# parameter grids per family — chosen so every combination is meaningful
GRID = [
    (fam_read_process_return, [("config", "config.json", "port"), ("profile", "profile.json", "email"),
                               ("order", "order.json", "total"), ("settings", "settings.yaml", "theme"),
                               ("invoice", "invoice.json", "amount"), ("device", "device.json", "serial"),
                               ("session", "session.json", "token"), ("report", "report.json", "summary")]),
    (fam_fetch_transform_return, [("weather", "https://api.weather.com/v1"), ("rates", "https://api.fx.com/latest"),
                                  ("stock", "https://api.stocks.io/quote"), ("news", "https://api.news.org/top"),
                                  ("geo", "https://api.geo.io/lookup"), ("crypto", "https://api.coins.io/price"),
                                  ("traffic", "https://api.maps.io/traffic"), ("sports", "https://api.scores.io/live")]),
    (fam_filter_return, [("users", "status", "active"), ("orders", "state", "paid"),
                         ("products", "category", "books"), ("events", "level", "critical"),
                         ("tickets", "priority", "high"), ("accounts", "tier", "premium"),
                         ("jobs", "status", "queued"), ("posts", "visibility", "public")]),
    (fam_create_emit, [("user", "email"), ("order", "total"), ("post", "title"), ("ticket", "subject"),
                       ("comment", "body"), ("invoice", "amount"), ("booking", "date"), ("review", "rating")]),
    (fam_hash_store, [("user",), ("account",), ("member",)]),
    (fam_iterate_log, [("orders", "orders"), ("users", "accounts"), ("jobs", "queue"), ("alerts", "alerts"),
                       ("events", "events"), ("payments", "transactions")]),
    (fam_compute_return, [("add", "a", "b", "+"), ("subtract", "a", "b", "-"),
                          ("multiply", "a", "b", "*"), ("divide", "a", "b", "/"), ("modulo", "a", "b", "%")]),
    (fam_validate_throw, [("order", "email"), ("account", "username"), ("payment", "amount"), ("booking", "date"),
                          ("signup", "name"), ("request", "token")]),
]

LANG_LABEL = {"python": "Python", "javascript": "JavaScript", "go": "Go"}
PHRASINGS = [
    "Translate this {lang} to ARO:\n```{tag}\n{src}\n```",
    "Rewrite this {lang} function as an ARO feature set:\n```{tag}\n{src}\n```",
    "Port this {lang} to ARO, preserving its behaviour:\n```{tag}\n{src}\n```",
]
TAG = {"python": "python", "javascript": "javascript", "go": "go"}


def main():
    rows, seen = [], set()
    checked = passed = sem_ok = 0
    aro_missing = False
    for fam, params in GRID:
        for i, args in enumerate(params):
            lang, src, aro, think, intent = fam(*args)
            checked += 1
            ok, err = config.aro_check_snippet(aro, timeout=15)
            if ok is None:
                aro_missing = True
                continue
            if not ok:
                print(f"  DROP (aro check fail) {fam.__name__}{args}: {err[:80]}")
                continue
            passed += 1
            got = verbs_in(aro)
            if not intent.issubset(got):
                print(f"  DROP (verb-intent miss) {fam.__name__}{args}: missing {intent - got}")
                continue
            sem_ok += 1
            output = f"<think>\n{think}\n</think>\n\n```aro\n{aro}\n```"
            for phrasing in PHRASINGS:
                instr = phrasing.format(lang=LANG_LABEL[lang], tag=TAG[lang], src=src)
                key = re.sub(r"\s+", " ", instr)
                if key in seen:
                    continue
                seen.add(key)
                rows.append({
                    "instruction": instr, "output": output,
                    "category": "translation", "task_type": "translation",
                    "source": "eval_gen_translation",
                    "intent_verbs": sorted(intent),
                })
    OUT.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    if aro_missing:
        print("  WARNING: `aro` binary not on PATH — could not validate; wrote nothing.")
    print(f"translation: checked {checked}, aro-check-passed {passed}, "
          f"verb-intent-passed {sem_ok} -> {len(rows)} pairs -> {OUT.name}")


if __name__ == "__main__":
    main()
