"""GEN_TODO.md parsing (the generation-failure inventory as data)."""

import importlib.util
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))

spec = importlib.util.spec_from_file_location(
    'gen_todo', SCRIPT_DIR / 'gen_todo.py')
gen_todo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen_todo)


def _entries(tmp_path):
    src = tmp_path / 'GEN_TODO.md'
    src.write_text(
        'Failed prompts from NB10 code generation (3 total).\n'
        '\n'
        '## 1. no_output\n'
        '\n'
        'todo list API with create, list, complete, and delete\n'
        '\n'
        '---\n'
        '\n'
        '## 2. no_output\n'
        '\n'
        'blog posts API with comments and draft/publish workflow\n'
        '\n'
        '---\n'
        '\n'
        '## 3. comment_heavy [grounded]\n'
        '\n'
        'SinkSyntax\n'
        '\n'
        '---\n')
    return gen_todo.parse(src)


def test_it_serves_the_real_inventory():
    entries = gen_todo.parse()
    s = gen_todo.stats(entries)
    # The file's own header says 369; the parser must read every one.
    assert s['total'] == 369, s
    assert s['by_kind']['no_output'] >= 360
    assert s['by_kind']['comment_heavy'] == 1


def test_numbers_kinds_and_tags_carry_through(tmp_path):
    entries = _entries(tmp_path)
    assert [e['n'] for e in entries] == [1, 2, 3]
    assert entries[2]['kind'] == 'comment_heavy'
    assert entries[2]['tag'] == 'grounded'
    assert entries[0]['tag'] is None


def test_prompt_text_is_the_body_between_separators(tmp_path):
    entries = _entries(tmp_path)
    assert entries[0]['prompt'] == ('todo list API with create, list, '
                                    'complete, and delete')
    # the separator itself does not leak into the prompt, and neither does
    # the next entry's header
    assert '---' not in entries[1]['prompt']
    assert 'comment_heavy' not in entries[1]['prompt']


def test_kind_and_tag_selection(tmp_path):
    entries = _entries(tmp_path)
    assert [e['n'] for e in entries if e['kind'] == 'no_output'] == [1, 2]
    assert [e['n'] for e in entries if e['tag'] == 'grounded'] == [3]


def test_an_entry_with_no_body_is_counted_not_dropped(tmp_path):
    src = tmp_path / 'GEN_TODO.md'
    src.write_text('## 1. no_output\n\n---\n')
    entries = gen_todo.parse(src)
    assert len(entries) == 1
    assert entries[0]['prompt'] == ''
    assert gen_todo.stats(entries)['empty_prompts'] == 1
