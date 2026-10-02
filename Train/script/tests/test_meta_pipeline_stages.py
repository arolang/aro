"""The meta pipeline's stage list matches what is on disk (GitLab #805).

`29_multimodel_doc_qa.py` and `32_notebook_pairs.py` were written, documented
in `Train/README.md`, and never run: the meta pipeline only knew how to
execute `<name>.ipynb`, so a stage written as a script could not be listed in
it at all. `data/29_doc_qa` stayed empty while the README described its
contents, and `knowledge_pairs` carried no rows from either sweep.

Nothing asserted the connection between the list and the filesystem, so there
was no way to notice. These tests are that assertion, in both directions —
a listed stage must exist, and the order must be the order the numbers claim.
"""
import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

SCRIPT_DIR = Path(__file__).resolve().parent.parent
META = SCRIPT_DIR / '00_META_PIPELINE.ipynb'

# ('14b', '32_notebook_pairs', 'Training pairs from …'),
ENTRY = re.compile(r"^\s*\('([^']+)',\s*'([^']+)',\s*'([^']*)'\),", re.M)


def stage_entries():
    """(num, name, description) for every stage the meta pipeline runs."""
    notebook = json.loads(META.read_text())
    for cell in notebook['cells']:
        source = ''.join(cell['source'])
        if 'NOTEBOOKS = [' not in source:
            continue
        body = source[source.index('NOTEBOOKS = ['):]
        body = body[:body.index('\n]')]
        return ENTRY.findall(body)
    raise AssertionError('no NOTEBOOKS list found in 00_META_PIPELINE.ipynb')


def leading_number(num: str) -> int:
    """What `--from NN` compares against, spelled the same way the loop spells it."""
    return int(''.join(ch for ch in num if ch.isdigit()) or 0)


class TestMetaPipelineStages(unittest.TestCase):

    def setUp(self):
        self.entries = stage_entries()

    def test_the_list_is_not_empty(self):
        self.assertGreater(len(self.entries), 20,
                           'the pipeline lost most of its stages')

    def test_every_listed_stage_exists_on_disk(self):
        # The #805 failure in one assertion. A stage named here must be
        # runnable: a notebook, or a script, which stage_runner also accepts.
        missing = [
            name for _num, name, _desc in self.entries
            if not (SCRIPT_DIR / f'{name}.ipynb').is_file()
            and not (SCRIPT_DIR / f'{name}.py').is_file()
        ]
        self.assertEqual(missing, [], f'listed but not on disk: {missing}')

    def test_the_notebook_pairs_stage_is_listed(self):
        # Named explicitly rather than left to the generic check: this is the
        # stage #805 is about, and a generic test passes just as happily with
        # it absent.
        names = [name for _num, name, _desc in self.entries]
        self.assertIn('32_notebook_pairs', names,
                      'the Learning-notebook pairs stage is not in the pipeline')

    # `27_package` runs BEFORE `26_post_release_validation` on purpose: 26
    # downloads and smoke-tests the model 27 just uploaded, so it has to run
    # last. The list is therefore ordered 27, 26 at the end, and the numbers
    # go backwards exactly once.
    #
    # That inversion is a real wart rather than a harmless one — `--from 27`
    # skips 26, which runs *after* 27 — but it predates #805 and is deliberate,
    # so this test records it instead of failing on it. Any OTHER inversion is
    # a mistake, which is what the assertion below is for.
    KNOWN_INVERSIONS = {(27, 26)}

    def test_stage_numbers_are_non_decreasing(self):
        # The loop runs the list in ORDER, but `--from NN` skips by NUMBER.
        # If the two disagree, resuming silently runs a different pipeline than
        # a fresh run does. `14b` parses to 14, which is the point of spelling
        # it that way.
        numbers = [leading_number(num) for num, _name, _desc in self.entries]
        for earlier, later in zip(numbers, numbers[1:]):
            if (earlier, later) in self.KNOWN_INVERSIONS:
                continue
            self.assertLessEqual(
                earlier, later,
                f'stage numbers go backwards ({earlier} then {later}); '
                '`--from` would skip a stage that runs before it')

    def test_the_known_inversion_is_still_there(self):
        # If 26/27 ever get reordered or renumbered, the exemption above stops
        # describing the pipeline and should go — a stale exemption is how a
        # guard quietly stops guarding.
        numbers = [leading_number(num) for num, _name, _desc in self.entries]
        seen = set(zip(numbers, numbers[1:]))
        stale = self.KNOWN_INVERSIONS - seen
        self.assertEqual(stale, set(),
                         f'exempted inversions that no longer occur: {stale}')

    def test_stage_identifiers_are_unique(self):
        # SKIP matches on the identifier string, so a duplicate would skip two
        # stages when the user named one.
        nums = [num for num, _name, _desc in self.entries]
        self.assertEqual(len(nums), len(set(nums)), f'duplicate stage ids in {nums}')

    def test_every_stage_has_a_description(self):
        # It is what the progress line prints; an empty one makes a long run
        # harder to follow for no saving.
        blank = [name for _num, name, desc in self.entries if not desc.strip()]
        self.assertEqual(blank, [], f'stages with no description: {blank}')


if __name__ == '__main__':
    unittest.main()
