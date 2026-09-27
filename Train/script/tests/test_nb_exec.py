"""End-to-end tests for nb_exec.py — the notebook runner that narrates.

The bug these exist for: under `jupyter nbconvert --execute` a stage's cell
output went into the output notebook and nothing reached stdout, so the meta
pipeline's stall watchdog polled a log that never grew and killed every stage
that ran longer than the stall window. The assertion that matters below is not
"the notebook ran" but "its output was readable WHILE it ran".

These spawn a real Jupyter kernel and are skipped where none is registered.
"""
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

NB_EXEC = Path(__file__).parent.parent / 'nb_exec.py'


def _kernel():
    """A registered Python kernel to run the fixtures with, or None."""
    try:
        out = subprocess.check_output(
            [sys.executable, '-m', 'jupyter', 'kernelspec', 'list', '--json'],
            text=True, stderr=subprocess.DEVNULL, timeout=60)
        specs = json.loads(out).get('kernelspecs', {})
    except Exception:
        return None
    for name in ('python3', 'aro-train', 'aro-python3'):
        if name in specs:
            return name
    return next(iter(specs), None)


KERNEL = _kernel()


def notebook(*sources):
    return {
        'cells': [{'cell_type': 'code', 'source': src, 'metadata': {},
                   'outputs': [], 'execution_count': None} for src in sources],
        'metadata': {}, 'nbformat': 4, 'nbformat_minor': 5,
    }


@unittest.skipIf(KERNEL is None, 'no Jupyter kernel registered')
class TestNbExec(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.log = self.root / 'stage.log'
        self.dest = self.root / 'out.ipynb'

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, nb):
        src = self.root / 'stage.ipynb'
        src.write_text(json.dumps(nb))
        return src

    def _run(self, src):
        with open(self.log, 'w') as fh:
            proc = subprocess.Popen(
                [sys.executable, '-u', str(NB_EXEC), str(src),
                 '--output', str(self.dest), '--kernel', KERNEL],
                stdout=fh, stderr=subprocess.STDOUT)
            return proc

    def test_output_is_readable_while_the_cell_is_still_running(self):
        """The regression: a long cell must leave a growing trail behind it."""
        src = self._write(notebook(
            "import time\n"
            "print('EARLY', flush=True)\n"
            "time.sleep(6)\n"
            "print('LATE', flush=True)\n"))
        proc = self._run(src)
        try:
            deadline = time.time() + 30
            while time.time() < deadline:
                if 'EARLY' in self.log.read_text(errors='replace'):
                    break
                time.sleep(0.2)
            else:
                self.fail('nothing was streamed within 30s')

            # Still mid-cell — the point of the test. Under nbconvert the log
            # held only "Converting notebook …" at this moment.
            self.assertIsNone(proc.poll(), 'the cell finished before we looked')
            self.assertNotIn('LATE', self.log.read_text(errors='replace'))
        finally:
            proc.wait(timeout=120)

        self.assertEqual(proc.returncode, 0)
        self.assertIn('LATE', self.log.read_text(errors='replace'))
        self.assertTrue(self.dest.is_file())

    def test_a_raising_cell_fails_the_stage_and_still_saves_the_notebook(self):
        src = self._write(notebook("print('before')", "raise KeyError('pairs')",
                                   "print('never')"))
        proc = self._run(src)
        proc.wait(timeout=120)
        self.assertEqual(proc.returncode, 1)

        log = self.log.read_text(errors='replace')
        self.assertIn('before', log)
        self.assertNotIn('never', log)
        self.assertIn("KeyError: 'pairs'", log)

        # The half-executed copy is the first thing anyone debugging wants;
        # nbconvert threw it away.
        self.assertTrue(self.dest.is_file())

        import stage_runner as sr
        self.assertEqual(sr.last_error_line(self.log), "KeyError: 'pairs'")

    def test_the_kernel_runs_in_the_notebooks_directory(self):
        """Every stage resolves config.py and its data paths from `Path('.')`."""
        src = self._write(notebook("import os; print('CWD=' + os.getcwd())"))
        proc = self._run(src)
        proc.wait(timeout=120)
        self.assertEqual(proc.returncode, 0)
        self.assertIn(f'CWD={src.parent.resolve()}',
                      self.log.read_text(errors='replace'))

    def test_a_missing_notebook_is_reported_not_crashed(self):
        proc = self._run(self.root / 'nope.ipynb')
        proc.wait(timeout=60)
        self.assertEqual(proc.returncode, 2)
        self.assertIn('no such notebook', self.log.read_text(errors='replace'))


if __name__ == '__main__':
    unittest.main()
