"""Caps that select by quality, not by insertion order.

TYPE_CAPS has said it in its own changelog since v5: the cap was applied
first-N-wins, so which rows survived was decided by which notebook saved
first. Now the recovery stages (36/37) append execution-graded applications
at the end of the corpus — the most expensive, most valuable rows — and
insertion-order caps would drop them first, every run.
"""

import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

import config  # noqa: E402


def _sample(task_type='code_generation', score=1.0, source='knowledge_pairs',
            instruction='write a todo list'):
    return {'task_type': task_type, 'score': score, 'source': source,
            'instruction': instruction, 'output': 'x'}


CAPS = {'code_generation': 2}

SAMPLES = [
    # the first pair is the weakest; under first-N-wins it survives and the
    # strongest pair is dropped
    _sample(score=0.3, source='weak:mix'),
    _sample(score=0.95, source='example:examples'),
    _sample(score=0.6, source='wiki:wiki'),
    _sample(task_type='correction'),        # uncapped type: everything survives
    _sample(task_type='correction'),
]


def test_the_cap_keeps_the_best_roof_not_nothing_the_first():
    kept, drops = config.select_within_caps(SAMPLES, caps=CAPS)
    cg = [s for s in kept if s['task_type'] == 'code_generation']
    scores = [0.95, 0.6]
    assert [s['score'] for s in cg] == scores
    assert drops == {'cap_exceeded:code_generation': 1}


def test_uncapped_types_keep_everything():
    kept, _drops = config.select_within_caps(SAMPLES, caps=CAPS)
    assert sum(1 for s in kept if s['task_type'] == 'correction') == 2


def test_equal_scores_fall_back_to_input_order():
    samples = [_sample(score=0.5, instruction='first'),
               _sample(score=0.5, instruction='second'),
               _sample(score=0.5, instruction='third')]
    kept, drops = config.select_within_caps(samples, caps={'code_generation': 2})
    assert [s['instruction'] for s in kept] == ['first', 'second']
    assert drops['cap_exceeded:code_generation'] == 1


def test_a_zero_cap_drops_the_whole_type():
    kept, drops = config.select_within_caps(SAMPLES, caps={'code_generation': 0})
    assert not [s for s in kept if s['task_type'] == 'code_generation']
    assert drops == {'cap_exceeded:code_generation': 3}


def test_unknown_types_get_the_default_cap():
    samples = [_sample(task_type='brand_new_type') for _ in range(5)]
    kept, drops = config.select_within_caps(
        samples, caps={}, default_cap=3)
    assert len(kept) == 3
    assert drops == {'cap_exceeded:brand_new_type': 2}


def test_real_caps_version_and_the_type_caps_table_unchanged():
    # item 3 only changes HOW a cap is applied, not its count
    assert config.TYPE_CAPS['code_generation'] == 3000
    assert config.TYPE_CAPS['correction'] == 3000
    assert config.TYPE_CAPS_VERSION.startswith('v5')


def test_source_quality_enters_the_rank():
    # equal score: the higher-quality source survives the cap
    samples = [_sample(score=0.9, source='weak:farm'),
               _sample(score=0.9, source='example:examples')]
    kept, _ = config.select_within_caps(samples, caps={'code_generation': 1})
    assert kept[0]['source'] == 'example:examples'
