"""Unit tests for sandbox.py (GitLab #804).

These assert the containment itself rather than any one call site: that a
generated program is given its own working directory, that the environment it
inherits is an allowlist and not the operator's, and — the actual regression —
that a relative file sink lands in the throwaway directory instead of in
Train/script.
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import sandbox  # noqa: E402


class TestSandboxEnv(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.work = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_home_and_tmpdir_are_inside_the_workdir(self):
        env = sandbox.sandbox_env(self.work, base={})
        self.assertEqual(env['HOME'], str(self.work / 'home'))
        self.assertEqual(env['TMPDIR'], str(self.work / 'tmp'))
        for key in ('XDG_CACHE_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME'):
            self.assertTrue(env[key].startswith(str(self.work)), key)

    def test_the_operators_environment_does_not_leak(self):
        base = {
            'PATH': '/usr/bin',
            'HOME': '/Users/someone',
            'HF_TOKEN': 'hf_secret',
            'AWS_SECRET_ACCESS_KEY': 'shhh',
            'ARO_APPLICATION_PATH': '/Users/someone/Projects/ARO-Application',
            'SSH_AUTH_SOCK': '/private/tmp/agent.sock',
        }
        env = sandbox.sandbox_env(self.work, base=base)
        self.assertEqual(env['PATH'], '/usr/bin')
        self.assertNotEqual(env['HOME'], '/Users/someone')
        for leaked in ('HF_TOKEN', 'AWS_SECRET_ACCESS_KEY',
                       'ARO_APPLICATION_PATH', 'SSH_AUTH_SOCK'):
            self.assertNotIn(leaked, env)

    def test_network_is_pointed_at_a_closed_port_by_default(self):
        env = sandbox.sandbox_env(self.work, base={})
        self.assertEqual(env['https_proxy'], 'http://127.0.0.1:1')
        self.assertEqual(env['HF_HUB_OFFLINE'], '1')

    def test_network_can_be_allowed_explicitly(self):
        env = sandbox.sandbox_env(self.work, allow_network=True, base={})
        self.assertNotIn('https_proxy', env)

    def test_extra_overrides_win(self):
        env = sandbox.sandbox_env(self.work, base={}, extra={'ARO_BIN': '/x/aro'})
        self.assertEqual(env['ARO_BIN'], '/x/aro')


class TestSandboxedRun(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.work = Path(self._tmp.name) / 'w'

    def tearDown(self):
        self._tmp.cleanup()

    def test_always_passes_cwd_and_env(self):
        seen = {}

        def fake(argv, **kw):
            seen.update(kw, argv=argv)
            return 'result'

        out = sandbox.sandboxed_run(['aro', 'run', '.'], self.work, _runner=fake)
        self.assertEqual(out, 'result')
        self.assertEqual(seen['cwd'], str(self.work))
        self.assertEqual(seen['env']['HOME'], str(self.work / 'home'))
        self.assertTrue(seen['capture_output'])

    def test_creates_the_private_home_and_tmp(self):
        sandbox.sandboxed_run(['true'], self.work, _runner=lambda *a, **k: None)
        self.assertTrue((self.work / 'home').is_dir())
        self.assertTrue((self.work / 'tmp').is_dir())

    def test_a_relative_write_lands_in_the_workdir(self):
        """The regression: a generated program's relative file sink."""
        script = ("import pathlib;"
                  "pathlib.Path('app.log').write_text('Log started')")
        sandbox.sandboxed_run([sys.executable, '-c', script], self.work,
                              timeout=30)
        self.assertEqual((self.work / 'app.log').read_text(), 'Log started')
        self.assertFalse((Path.cwd() / 'app.log').exists())

    def test_the_process_sees_the_sandbox_home(self):
        script = "import os; print(os.environ['HOME'])"
        proc = sandbox.sandboxed_run([sys.executable, '-c', script], self.work,
                                     timeout=30)
        self.assertEqual(proc.stdout.strip(), str(self.work / 'home'))
        self.assertNotEqual(proc.stdout.strip(), os.path.expanduser('~'))


class TestProgramDir(unittest.TestCase):
    def test_writes_the_program_and_its_contract(self):
        with sandbox.program_dir('(Application-Start: X) { }',
                                 {'openapi.yaml': 'openapi: 3.0.3'}) as d:
            self.assertEqual((d / 'main.aro').read_text(),
                             '(Application-Start: X) { }')
            self.assertEqual((d / 'openapi.yaml').read_text(), 'openapi: 3.0.3')
            kept = d
        self.assertFalse(kept.exists())

    def test_is_created_outside_the_checkout(self):
        repo = Path(__file__).resolve().parents[3]
        with sandbox.program_dir('x') as d:
            self.assertNotIn(str(repo), str(d.resolve()))

    def test_run_program_dir_passes_the_directory_as_the_last_argument(self):
        script = ("import sys, pathlib;"
                  "print((pathlib.Path(sys.argv[1]) / 'main.aro').read_text())")
        proc = sandbox.run_program_dir([sys.executable, '-c', script],
                                       'hello aro', timeout=30)
        self.assertEqual(proc.stdout.strip(), 'hello aro')


class TestMirroredDir(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.source = Path(self._tmp.name) / 'course'
        (self.source / 'data').mkdir(parents=True)
        (self.source / 'lesson.repl').write_text('{}')
        (self.source / 'data' / 'sample.csv').write_text('a,b\n1,2\n')

    def tearDown(self):
        self._tmp.cleanup()

    def test_siblings_are_readable_in_the_mirror(self):
        with sandbox.mirrored_dir(self.source) as d:
            self.assertEqual((d / 'data' / 'sample.csv').read_text(), 'a,b\n1,2\n')
            self.assertTrue((d / 'lesson.repl').is_file())

    def test_writes_do_not_reach_the_source(self):
        with sandbox.mirrored_dir(self.source) as d:
            (d / 'written-by-a-cell.txt').write_text('x')
        self.assertFalse((self.source / 'written-by-a-cell.txt').exists())

    def test_each_mirror_starts_clean(self):
        """Why the notebook stage dropped cells as non-reproducible."""
        with sandbox.mirrored_dir(self.source) as first:
            (first / 'state.txt').write_text('pass 1')
        with sandbox.mirrored_dir(self.source) as second:
            self.assertFalse((second / 'state.txt').exists())


class TestAgainstTheRealRuntime(unittest.TestCase):
    """The actual regression, with a real `aro run`, when one is available."""

    STRAY = ('(Application-Start: Stray Writer) {\n'
             '    Write "Hello, ARO!" to the <file: "test.txt">.\n'
             '    Return an <OK: status> for the <startup>.\n'
             '}\n')

    def setUp(self):
        import shutil
        self.aro = os.environ.get('ARO_BIN') or shutil.which('aro')
        if not self.aro:
            self.skipTest('no aro binary on PATH')
        self._tmp = tempfile.TemporaryDirectory()
        self.pretend_pipeline_cwd = Path(self._tmp.name)

    def tearDown(self):
        if hasattr(self, '_tmp'):
            self._tmp.cleanup()

    def test_the_write_lands_in_the_sandbox_not_the_working_directory(self):
        here = os.getcwd()
        os.chdir(self.pretend_pipeline_cwd)
        try:
            with sandbox.program_dir(self.STRAY) as workdir:
                proc = sandbox.sandboxed_run([self.aro, 'run', str(workdir)],
                                             workdir, timeout=60)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertTrue((workdir / 'test.txt').exists(),
                                'the program wrote nothing — has the file sink '
                                'syntax changed? The containment claim is only '
                                'meaningful while this writes something.')
            self.assertEqual(list(self.pretend_pipeline_cwd.iterdir()), [],
                             'a generated program wrote into the working '
                             'directory — the #804 regression is back')
        finally:
            os.chdir(here)


class TestTimeoutPropagates(unittest.TestCase):
    def test_timeout_raises_for_the_caller_to_classify(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(subprocess.TimeoutExpired):
                sandbox.sandboxed_run([sys.executable, '-c',
                                       'import time; time.sleep(5)'],
                                      Path(tmp), timeout=0.5)


if __name__ == '__main__':
    unittest.main()
