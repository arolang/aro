#!/usr/bin/env python3
"""Generate contract-first FULL-application training pairs: an openapi.yaml that
defines the object schema (components/schemas) plus the ARO feature sets that
implement each operationId. Validated as a multi-file app via aro check
(main.aro + openapi.yaml together)."""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/Users/kris/Projects/ARO/ARO-Lang/Train/script")
import config  # noqa: E402

OUT = HERE / "openapi_apps.jsonl"

ENTITIES = [
    ("user", "users", [("id", "integer"), ("name", "string"), ("email", "string")]),
    ("order", "orders", [("id", "integer"), ("total", "number"), ("status", "string")]),
    ("product", "products", [("id", "integer"), ("name", "string"), ("price", "number")]),
    ("ticket", "tickets", [("id", "integer"), ("title", "string"), ("status", "string")]),
    ("invoice", "invoices", [("id", "integer"), ("amount", "number"), ("paid", "boolean")]),
    ("comment", "comments", [("id", "integer"), ("body", "string"), ("author", "string")]),
    ("booking", "bookings", [("id", "integer"), ("date", "string"), ("guests", "integer")]),
    ("device", "devices", [("id", "integer"), ("name", "string"), ("online", "boolean")]),
    ("account", "accounts", [("id", "integer"), ("owner", "string"), ("balance", "number")]),
    ("review", "reviews", [("id", "integer"), ("rating", "integer"), ("text", "string")]),
    ("customer", "customers", [("id", "integer"), ("name", "string"), ("tier", "string")]),
    ("payment", "payments", [("id", "integer"), ("amount", "number"), ("method", "string")]),
    ("shipment", "shipments", [("id", "integer"), ("carrier", "string"), ("delivered", "boolean")]),
    ("subscription", "subscriptions", [("id", "integer"), ("plan", "string"), ("active", "boolean")]),
    ("employee", "employees", [("id", "integer"), ("name", "string"), ("role", "string")]),
    ("project", "projects", [("id", "integer"), ("name", "string"), ("owner", "string")]),
    ("task", "tasks", [("id", "integer"), ("title", "string"), ("done", "boolean")]),
    ("article", "articles", [("id", "integer"), ("title", "string"), ("body", "string")]),
    ("category", "categories", [("id", "integer"), ("name", "string"), ("slug", "string")]),
    ("vendor", "vendors", [("id", "integer"), ("name", "string"), ("rating", "number")]),
    ("coupon", "coupons", [("id", "integer"), ("code", "string"), ("percent", "number")]),
    ("address", "addresses", [("id", "integer"), ("city", "string"), ("country", "string")]),
    ("notification", "notifications", [("id", "integer"), ("message", "string"), ("read", "boolean")]),
    ("session", "sessions", [("id", "integer"), ("token", "string"), ("expired", "boolean")]),
    ("warehouse", "warehouses", [("id", "integer"), ("name", "string"), ("capacity", "integer")]),
    ("refund", "refunds", [("id", "integer"), ("amount", "number"), ("reason", "string")]),
    ("lead", "leads", [("id", "integer"), ("name", "string"), ("score", "integer")]),
    ("campaign", "campaigns", [("id", "integer"), ("name", "string"), ("budget", "number")]),
    ("sensor", "sensors", [("id", "integer"), ("label", "string"), ("value", "number")]),
    ("reservation", "reservations", [("id", "integer"), ("table", "integer"), ("time", "string")]),
]


def cap(s):
    return s[0].upper() + s[1:]


def make_openapi(e, plural, fields):
    props = "\n".join(f"          {n}:\n            type: {t}" for n, t in fields)
    required = ", ".join(n for n, _ in fields[:1])
    return f"""openapi: 3.0.3
info:
  title: {cap(e)} API
  version: 1.0.0
paths:
  /{plural}:
    get:
      operationId: list{cap(plural)}
    post:
      operationId: create{cap(e)}
  /{plural}/{{id}}:
    get:
      operationId: get{cap(e)}
    put:
      operationId: update{cap(e)}
    delete:
      operationId: delete{cap(e)}
components:
  schemas:
    {cap(e)}:
      type: object
      required: [{required}]
      properties:
{props}
"""


def make_aro(e, plural, fields):
    repo = f"{e}-repository"
    return f"""(list{cap(plural)}: {cap(e)} API) {{
    Retrieve the <{plural}> from the <{repo}>.
    Return an <OK: status> with <{plural}>.
}}

(get{cap(e)}: {cap(e)} API) {{
    Extract the <key> from the <pathParameters: id>.
    Retrieve the <{e}> from the <{repo}> where <id> is <key>.
    Return an <OK: status> with <{e}>.
}}

(create{cap(e)}: {cap(e)} API) {{
    Extract the <data> from the <request: body>.
    Create the <{e}> with <data>.
    Store the <{e}> into the <{repo}>.
    Emit a <{cap(e)}Created: event> with <{e}>.
    Return a <Created: status> with <{e}>.
}}

(update{cap(e)}: {cap(e)} API) {{
    Extract the <key> from the <pathParameters: id>.
    Extract the <data> from the <request: body>.
    Retrieve the <{e}> from the <{repo}> where <id> is <key>.
    Transform the <updated> from the <{e}> with <data>.
    Store the <updated> into the <{repo}>.
    Return an <OK: status> with <updated>.
}}

(delete{cap(e)}: {cap(e)} API) {{
    Extract the <key> from the <pathParameters: id>.
    Retrieve the <{e}> from the <{repo}> where <id> is <key>.
    Return an <OK: status> with <{e}>.
}}"""


INSTR = [
    "Write a complete ARO application for a {e} REST API. Define the {e} object schema in openapi.yaml and implement the list, get, create, update, and delete operations.",
    "Build a contract-first ARO app: an openapi.yaml with a {e} schema (object definition) plus the feature sets implementing each operationId.",
    "Create a full ARO {e} service with an OpenAPI contract that defines the {e} object and ARO handlers for full CRUD.",
    "I need a complete contract-first ARO {e} service — openapi.yaml with the {e} components schema and one feature set per operationId.",
    "Generate a working ARO application: openapi.yaml defining the {e} object plus ARO feature sets for listing, getting, creating, updating, and deleting {e}s.",
    "Scaffold an ARO {e} CRUD API. Put the object definition in openapi.yaml (components/schemas) and implement every operationId as an ARO feature set.",
]


def main():
    n = 0
    with open(OUT, "w") as f:
        for i, (e, plural, fields) in enumerate(ENTITIES):
            yaml = make_openapi(e, plural, fields)
            aro = make_aro(e, plural, fields)
            passed, err = config.aro_check_snippet(aro, timeout=20, extra_files={"openapi.yaml": yaml})
            if not passed:
                print(f"FAIL {e}: {err[:120]}")
                continue
            for j, tmpl in enumerate(INSTR):
                rec = {
                    "instruction": tmpl.format(e=e),
                    "output": f"**openapi.yaml**\n```yaml\n{yaml}```\n\n**{e}.aro**\n```aro\n{aro}\n```",
                    "category": "openapi",
                    "task_type": "full_application",
                    "source": "eval_gen_openapi",
                }
                f.write(json.dumps(rec) + "\n")
                n += 1
    print(f"openapi full-app pairs: {n}")


if __name__ == "__main__":
    main()
