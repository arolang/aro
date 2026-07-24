#!/usr/bin/env python3
"""Error-injection engine for error→fix training pairs.

Each transform takes a KNOWN-GOOD ARO program and returns a broken variant plus
a short label of the error class. We keep a pair only when it is validated:
  * the original passes `aro check`
  * the broken version FAILS `aro check`
  * broken != original (guarantees a meaningful diff — no trivial_fix_no_diff)

Error classes mirror the real failure modes from FIXTRAIN.md and the live
`aro ask` eval (esp. hallucinated actions, the model's #1 weakness).
"""
import re

VERB_LINE = re.compile(r"^(\s*)([A-Z][a-zA-Z.]+)(\s)", re.M)

# Invented verbs the model actually emits (anti-hallucination signal).
INVENTED = {
    "Store": "Save", "Retrieve": "Get", "Return": "Respond", "Emit": "Dispatch",
    "Log": "Print", "Compute": "Calculate", "Validate": "Verify", "Create": "Build",
    "Extract": "Fetch2", "Render": "Draw", "Filter": "Select", "Send": "Deliver",
    "Group": "Bucket", "Split": "Divide", "Transform": "Convert", "Commit": "Checkin",
    "Retrieve2": "Query", "Update": "Modify", "Delete": "Remove2",
}


def _first_stmt_line(code):
    lines = code.split("\n")
    for i, l in enumerate(lines):
        s = l.strip()
        if s and not s.startswith("(") and not s.startswith("}") and not s.startswith("(*"):
            return i, lines
    return None, lines


def drop_period(code):
    i, lines = _first_stmt_line(code)
    if i is None or not lines[i].rstrip().endswith("."):
        return None
    lines[i] = lines[i].rstrip()[:-1]
    return "\n".join(lines), "missing_period"


def plus_for_concat(code):
    if " ++ " not in code:
        return None
    return code.replace(" ++ ", " + ", 1), "string_concat_plus_not_plusplus"


def invented_verb(code):
    for good, bad in INVENTED.items():
        m = re.search(rf"^(\s*){good}(\s)", code, re.M)
        if m:
            broken = re.sub(rf"^(\s*){good}(\s)", rf"\g<1>{bad}\g<2>", code, count=1, flags=re.M)
            return broken, f"hallucinated_action_{bad}"
    return None


def wrong_prep_log(code):
    if "to the <console>" not in code:
        return None
    return code.replace("to the <console>", "for the <console>", 1), "wrong_preposition_log"


def strip_angle(code):
    m = re.search(r"<([a-z][a-zA-Z0-9-]*)>", code)
    if not m:
        return None
    return code[:m.start()] + m.group(1) + code[m.end():], "missing_angle_brackets"


def drop_return(code):
    lines = code.split("\n")
    keep = [l for l in lines if not re.match(r"\s*(Return|Throw)\b", l)]
    if len(keep) == len(lines):
        return None
    return "\n".join(keep), "missing_return_or_throw"


def drop_activity(code):
    # "(Name: Activity) {"  ->  "(Name) {"
    broken = re.sub(r"\(([^():\n]+):[^()\n]+\)\s*\{", r"(\1) {", code, count=1)
    if broken == code:
        return None
    return broken, "missing_business_activity"


def compute_arith_with(code):
    m = re.search(r"Compute the (<[^>]+>) from ([^.\n]*[*+/%-][^.\n]*)\.", code)
    if not m:
        return None
    broken = code[:m.start()] + f"Compute the {m.group(1)} from the {m.group(1)} with {m.group(1)}." + code[m.end():]
    return broken, "compute_arith_wrong_with_form"


def emit_swap(code):
    m = re.search(r"Emit an? (<[^>]+: event>) with (<[^>]+>)\.", code)
    if not m:
        return None
    ev, data = m.group(1), m.group(2)
    broken = code[:m.start()] + f"Emit the {data} to the {ev.split(':')[0]}>." + code[m.end():]
    return broken.replace(">>", ">"), "emit_wrong_shape"


def add_hallucinated_action(code):
    # insert an invented statement before the Return/Throw
    lines = code.split("\n")
    for i, l in enumerate(lines):
        if re.match(r"\s*(Return|Throw)\b", l):
            indent = re.match(r"(\s*)", l).group(1)
            lines.insert(i, f"{indent}Subscribe to the <events>.")
            return "\n".join(lines), "hallucinated_action_Subscribe"
    return None


def lowercase_verb(code):
    i, lines = _first_stmt_line(code)
    if i is None:
        return None
    m = re.match(r"(\s*)([A-Z])([a-z]+\s)", lines[i])
    if not m:
        return None
    lines[i] = f"{m.group(1)}{m.group(2).lower()}{m.group(3)}" + lines[i][m.end():]
    return "\n".join(lines), "verb_not_capitalized"


def unclosed_brace(code):
    s = code.rstrip()
    if not s.endswith("}"):
        return None
    return s[:-1], "unclosed_feature_set_brace"


def unclosed_angle(code):
    m = re.search(r"<([a-z][a-zA-Z0-9-]*)>", code)
    if not m:
        return None
    return code[:m.start()] + f"<{m.group(1)}" + code[m.end():], "unclosed_angle_bracket"


def dangling_with(code):
    m = re.search(r"( with )(<[^>]+>|\"[^\"]*\"|\{[^}]*\})(\.)", code)
    if not m:
        return None
    return code[:m.start()] + " with." + code[m.end():], "dangling_with_no_value"


TRANSFORMS = [
    drop_period, plus_for_concat, invented_verb, wrong_prep_log, strip_angle,
    drop_return, drop_activity, compute_arith_with, emit_swap, add_hallucinated_action,
    lowercase_verb, unclosed_brace, unclosed_angle, dangling_with,
]


def apply_transform(code, t):
    r = t(code)
    if r is None:
        return None
    broken, label = r
    if broken.strip() == code.strip():
        return None
    return broken, label
