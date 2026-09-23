"""Unit tests for stage_runner.py (GitLab #803).

The stall watchdog is the part that has to be right: too eager and it kills a
healthy six-hour fine-tune, too lax and the pipeline hangs until morning. It is
driven here by an injected clock and a fake process, so both outcomes are
asserted in milliseconds.
"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import stage_runner as sr  # noqa: E402


class FakeProc:
    """A process that finishes after `alive_polls` polls, or never."""

    def __init__(self, alive_polls=0, returncode=0, log=None, writes=()):
        self._left = alive_polls
        self.returncode = None
        self._final = returncode
        self._log = log
        self._writes = list(writes)     # poll index -> text appended to the log
        self._polls = 0
        self.terminated = self.killed = False

    def poll(self):
        if self._log is not None and self._writes:
            when, text = self._writes[0]
            if self._polls >= when:
                with open(self._log, 'a') as fh:
                    fh.write(text)
                self._writes.pop(0)
        self._polls += 1
        if self._left <= 0:
            self.returncode = self._final
            return self._final
        self._left -= 1
        return None

    def terminate(self):
        self.terminated = True
        self.returncode = -15

    def kill(self):
        self.killed = True
        self.returncode = -9

    def wait(self, timeout=None):
        self.returncode = self.returncode if self.returncode is not None else -15
        return self.returncode


class StageRunnerCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.scripts = self.root / 'script'
        self.out = self.root / 'out'
        self.scripts.mkdir()
        (self.scripts / 'demo.ipynb').write_text('{"cells": []}')
        self.now = [0.0]

    def tearDown(self):
        self._tmp.cleanup()

    def _clock(self):
        return self.now[0]

    def _sleep(self, seconds):
        self.now[0] += seconds

    def _run(self, proc, **kw):
        return sr.run_notebook('demo', self.scripts, self.out, 'python3',
                               poll_interval=60, _clock=self._clock,
                               _sleep=self._sleep, _popen=lambda *a, **k: proc,
                               **kw)


class TestStallWatchdog(StageRunnerCase):
    def test_a_silent_stage_is_killed(self):
        proc = FakeProc(alive_polls=10_000)
        result = self._run(proc, stall_timeout=300)
        self.assertEqual(result['status'], 'stalled')
        self.assertTrue(proc.terminated)
        self.assertIn('no output for 5 min', result['error'])

    def test_a_stage_that_keeps_writing_is_never_killed(self):
        """The regression that made timeouts get disabled in the first place."""
        log = self.out / 'demo.log'
        writes = [(i, f'iter {i}: train loss 0.4\n') for i in range(1, 40)]
        proc = FakeProc(alive_polls=38, returncode=0, log=log, writes=writes)
        result = self._run(proc, stall_timeout=300)
        self.assertEqual(result['status'], 'done')
        self.assertFalse(proc.terminated)
        # It ran far longer than the stall window and was left alone.
        self.assertGreater(result['duration'], 300)

    def test_hard_cap_when_asked_for(self):
        log = self.out / 'demo.log'
        writes = [(i, f'line {i}\n') for i in range(1, 100)]
        proc = FakeProc(alive_polls=10_000, log=log, writes=writes)
        result = self._run(proc, stall_timeout=0, max_runtime=600)
        self.assertEqual(result['status'], 'timeout')
        self.assertIn('600s hard cap', result['error'])

    def test_no_cap_by_default(self):
        """A stage that is still writing is still working."""
        import inspect
        params = inspect.signature(sr.run_notebook).parameters
        self.assertEqual(params['max_runtime'].default, 0)
        self.assertEqual(params['stall_timeout'].default, sr.DEFAULT_STALL_TIMEOUT)

    def test_failure_is_reported_with_the_last_log_line(self):
        log = self.out / 'demo.log'
        proc = FakeProc(alive_polls=1, returncode=1, log=log,
                        writes=[(0, '[NbConvertApp] Converting\nValueError: boom\n')])
        result = self._run(proc, stall_timeout=300)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['error'], 'ValueError: boom')

    def test_missing_notebook(self):
        result = sr.run_notebook('nope', self.scripts, self.out, 'python3')
        self.assertEqual(result['status'], 'missing')

    def test_no_kernel(self):
        result = sr.run_notebook('demo', self.scripts, self.out, None)
        self.assertEqual(result['status'], 'failed')
        self.assertIn('kernel', result['error'])


class TestStageOptions(unittest.TestCase):
    def test_limit_truncates(self):
        opts = sr.StageOptions(limit=2)
        self.assertEqual(opts.apply([1, 2, 3, 4]), [1, 2])

    def test_zero_limit_means_everything(self):
        opts = sr.StageOptions(limit=0)
        items = [1, 2, 3]
        self.assertIs(opts.apply(items), items)

    def test_from_env(self):
        opts = sr.StageOptions.from_env({'ARO_TRAIN_DRY_RUN': 'yes',
                                         'ARO_TRAIN_LIMIT': '5'})
        self.assertTrue(opts.dry_run)
        self.assertEqual(opts.limit, 5)

    def test_from_env_defaults_and_junk(self):
        self.assertEqual(sr.StageOptions.from_env({}), sr.StageOptions())
        junk = sr.StageOptions.from_env({'ARO_TRAIN_LIMIT': 'lots'})
        self.assertEqual(junk.limit, 0)
        negative = sr.StageOptions.from_env({'ARO_TRAIN_LIMIT': '-3'})
        self.assertEqual(negative.limit, 0)

    def test_from_args(self):
        import argparse
        ap = sr.add_stage_arguments(argparse.ArgumentParser())
        opts = sr.StageOptions.from_args(ap.parse_args(['--dry-run', '--limit', '3']))
        self.assertEqual(opts, sr.StageOptions(dry_run=True, limit=3))
        self.assertEqual(opts.describe(), 'dry-run, limit=3')
        self.assertEqual(sr.StageOptions().describe(), 'full run')


class TestLastErrorLine(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / 'x.log'

    def tearDown(self):
        self._tmp.cleanup()

    def test_skips_nbconvert_noise(self):
        self.log.write_text('KeyError: pairs\n[NbConvertApp] writing\n\n')
        self.assertEqual(sr.last_error_line(self.log), 'KeyError: pairs')

    def test_missing_log(self):
        self.assertEqual(sr.last_error_line(self.log / 'nope'), 'see log')


if __name__ == '__main__':
    unittest.main()
