"""Tests for the shipped system prompt (GitLab #808).

A system prompt is the model's standing instructions. The one that shipped was
14 475 bytes, said the same things twice, was cut off mid-word, and taught a
`Compare` form that cannot run. Size is the least of that: these tests pin the
correctness properties — one statement of each rule, nothing stale, the whole
closed qualifier set present, and the same string in a training row as in a
served request — and keep a bound on the size so the scrape cannot creep back.

No model and no knowledge.json: the prompt is generated from the catalogues,
which are tracked files.
"""
import json
import re
import sys
import unittest
from collections import Counter
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402

PROMPT = config.build_system_prompt({})
ACTIONS = json.loads((SCRIPT_DIR / 'aro_action_catalog.json').read_text())
QUALIFIERS = json.loads((SCRIPT_DIR / 'aro_qualifier_catalog.json').read_text())

# The prompt cannot reach the ~4 KB the issue estimated without dropping the
# action and qualifier catalogues, which are what make "use only these verbs"
# and "the qualifier set is closed" enforceable. The bound is set above the
# current size with room for the catalogues to grow, and far below the 14 475
# bytes that prompted the issue.
MAX_BYTES = 9000


class TestNothingStale(unittest.TestCase):
    """What the prompt teaches has to be the language that exists."""

    def test_the_pre_469_compare_form_is_gone(self):
        # `Compare the <a> against the <b>.` rebinds its own first operand and
        # cannot run under immutability (GitLab #469). The shipped prompt taught
        # it in one section and the correct form in another.
        self.assertNotIn('Compare the <first-length> against', PROMPT)
        self.assertNotRegex(
            PROMPT, r'Compare the <\w[\w-]*> against the <\w[\w-]*>\.',
            'the two-operand Compare is back in the prompt')

    def test_it_teaches_the_form_that_runs(self):
        self.assertIn('Compare the <same> from the <a> against the <b>.', PROMPT)
        self.assertIn('<same: matches>', PROMPT)

    def test_it_is_not_truncated(self):
        # The old builder sliced a pasted scrape at 4000 characters and ended
        # mid-word. A prompt that stops mid-sentence teaches the model that
        # instructions end arbitrarily.
        self.assertNotIn('built-in ope', PROMPT)
        self.assertTrue(PROMPT.rstrip().endswith('produce syntactically valid ARO.'),
                        PROMPT[-120:])

    def test_max_syntax_chars_no_longer_truncates_anything(self):
        self.assertEqual(config.build_system_prompt({}, max_syntax_chars=10), PROMPT)

    def test_no_documentation_scrape_leaks_in(self):
        # kb['aro_syntax'] was pasted in raw; the prompt must not read it again.
        kb = {'aro_syntax': 'SENTINEL-SCRAPE-CONTENT', 'actions': []}
        self.assertNotIn('SENTINEL-SCRAPE-CONTENT', config.build_system_prompt(kb))

    def test_map_and_qualifier_rules_match_the_live_language(self):
        self.assertIn('Map the <names> from the <users> with name.', PROMPT)
        self.assertIn('Sort the <s> for the <xs>.', PROMPT)
        self.assertIn('Extract the <f: first> from the <xs>.', PROMPT)
        self.assertIn('as Float', PROMPT)


class TestNoDuplication(unittest.TestCase):
    def test_no_paragraph_appears_twice(self):
        paras = [p.strip() for p in re.split(r'\n\s*\n', PROMPT) if len(p.strip()) > 60]
        repeats = [p.splitlines()[0] for p, n in Counter(paras).items() if n > 1]
        self.assertEqual(repeats, [])

    def test_no_substantial_line_appears_twice(self):
        # The shipped prompt carried the whole Application-End block twice, once
        # as prose and once fenced, so the repeats were line-for-line.
        lines = [l.strip() for l in PROMPT.splitlines() if len(l.strip()) > 40]
        repeats = [l for l, n in Counter(lines).items() if n > 1]
        self.assertEqual(repeats, [])

    def test_the_feature_set_skeleton_is_stated_once(self):
        self.assertEqual(PROMPT.count('(Application-Start: My App)'), 1)


class TestCatalogueCoverage(unittest.TestCase):
    """Generated from the catalogues, so it cannot silently fall behind them."""

    def test_every_action_verb_is_listed(self):
        missing = []
        for name, entry in ACTIONS.items():
            verb = (entry.get('aliases') or [name])[0].capitalize()
            if not re.search(rf'\b{re.escape(verb)}\b', PROMPT):
                missing.append(verb)
        self.assertEqual(missing, [])

    def test_every_builtin_qualifier_is_listed(self):
        names = [n for n, e in QUALIFIERS.items()
                 if not isinstance(e, dict) or e.get('namespace', '_builtin') == '_builtin']
        missing = [n for n in names if not re.search(rf'(?<![\w-]){re.escape(n)}(?![\w-])', PROMPT)]
        self.assertEqual(missing, [])

    def test_a_new_qualifier_reaches_the_prompt(self):
        listed = config._prompt_qualifier_reference({'zzz-new': {'namespace': '_builtin'}})
        self.assertIn('zzz-new', listed)

    def test_the_closed_set_is_stated_as_closed(self):
        self.assertIn('CLOSED set', PROMPT)
        self.assertIn('Never invent one', PROMPT)

    def test_prepositions_come_from_the_catalogue(self):
        # Log's prepositions in the catalogue must be the ones the prompt shows.
        entry = ACTIONS['log']
        token = 'Log=' if entry.get('aliases', [])[1:] else 'Log:'
        self.assertIn(token, PROMPT)
        for prep in entry['prepositions']:
            self.assertIn(prep, PROMPT)

    def test_the_fallback_works_without_the_catalogue_file(self):
        kb = {'actions': [{'verbs': ['Frobnicate'], 'role': 'own',
                           'prepositions': ['with']}]}
        ref = config._prompt_action_reference(catalog={}, kb=kb)
        self.assertIn('Frobnicate:with', ref)


class TestTools(unittest.TestCase):
    def test_the_protocol_is_shown_once_and_correctly(self):
        self.assertEqual(PROMPT.count('<tool_call>'), 1)
        m = re.search(r'<tool_call>(\{.*?\})</tool_call>', PROMPT)
        self.assertIsNotNone(m)
        payload = json.loads(m.group(1))
        self.assertIn('name', payload)
        self.assertIn('arguments', payload)

    def test_it_warns_about_the_fenced_impostor(self):
        self.assertIn('runs nothing', PROMPT)
        self.assertIn('aro_mcp_', PROMPT)

    def test_it_names_the_tool_the_cli_registers_and_the_prompt_forgot(self):
        # Sources/AROAsk/Tools/KnowledgeTool.swift registers aro_knowledge; the
        # shipped prompt never mentioned it, so the model could not use it.
        self.assertIn('aro_knowledge', PROMPT)

    def test_it_does_not_advertise_a_tool_that_does_not_exist(self):
        listed = set(re.findall(r'^  ([a-z_]+)\(', PROMPT, re.M))
        try:
            import release_gate
        except ImportError:  # pragma: no cover
            self.skipTest('release_gate unavailable')
        self.assertLessEqual(listed, set(release_gate.KNOWN_TOOLS))


class TestOneContract(unittest.TestCase):
    """Training rows and served requests must carry the same string."""

    def test_the_training_prompt_is_the_served_prompt(self):
        self.assertEqual(config.training_system_prompt({}), PROMPT)

    def test_it_is_deterministic(self):
        self.assertEqual(config.build_system_prompt({}), config.build_system_prompt({}))

    def test_the_thinking_rows_carry_the_system_prompt(self):
        # NB24 built rows with only user and assistant turns while NB19 (DPO),
        # NB23 (material) and the conversation generator all carried the full
        # prompt, so the model was fine-tuned on two contracts and served under
        # one of them. Its before/after evaluation had the same gap.
        nb = json.loads((SCRIPT_DIR / '24_thinking_finetune.ipynb').read_text())
        src = '\n'.join(''.join(c['source']) for c in nb['cells']
                        if c['cell_type'] == 'code')
        self.assertIn('build_system_prompt', src)
        self.assertEqual(src.count('"role": "system"'), 2,
                         'both the training rows and the eval prompt need it')

    def test_every_training_stage_uses_one_prompt(self):
        # The stages that build chat rows must all reach the same builder: NB24
        # (thinking), NB23 (material), NB19 (preference) and the conversation
        # generator that feeds NB25.
        sources = ['24_thinking_finetune.ipynb', '23_material_finetune.ipynb',
                   '19_preference_sft.ipynb']
        for name in sources:
            text = (SCRIPT_DIR / name).read_text()
            self.assertIn('build_system_prompt', text, name)
        gen = SCRIPT_DIR.parent / 'eval_derived' / 'generators' / 'gen_conversations.py'
        if gen.exists():
            self.assertIn('build_system_prompt', gen.read_text())


# The prompt that shipped with v1.1.0, as a file on disk. The comparison the
# issue makes. The old builder run against *today's* catalogues produced 15 867
# bytes — the shipped file is smaller only because the catalogue has grown since
# August — so the like-for-like reduction is larger than this number suggests.
SHIPPED_BYTES = 14475


class TestSize(unittest.TestCase):
    def test_it_is_far_smaller_than_the_prompt_that_shipped(self):
        self.assertLess(len(PROMPT), MAX_BYTES,
                        f'prompt grew to {len(PROMPT)} bytes')
        self.assertLess(len(PROMPT), SHIPPED_BYTES * 0.55,
                        'the point of #808 was roughly halving it')

    def test_it_still_says_everything_it_needs_to(self):
        for required in ('Verb the <Result>', 'DIRECTORY', 'immutable',
                         'Happy path only', 'operationId', 'Handler',
                         'Keepalive', '++'):
            self.assertIn(required, PROMPT, required)


if __name__ == '__main__':
    unittest.main()
