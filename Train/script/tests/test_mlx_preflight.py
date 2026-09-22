"""Unit tests for mlx_preflight.py (GitLab #793).

The checks that matter here are byte-level and version-level, so they can be
exercised with synthetic metallibs on any platform — no Apple Silicon, no mlx,
no GPU. That is the point: the preflight is what stands between an operator and
a crash six hours into a run, so it must itself be provable.
"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import mlx_preflight as mp  # noqa: E402


def _metallib(tmp: Path, dtypes) -> Path:
    """A fake metallib containing the named gather-kernel instantiations."""
    blob = b'\x00' * 64
    for dtype in dtypes:
        blob += (b'padding' +
                 b'steel_gather_mm_rhs_nax_nt_' + dtype.encode() + b'_' +
                 dtype.encode() + b'_bm64_bn128_bk128_wm2_wn4' + b'\x00' * 8)
    path = tmp / 'mlx.metallib'
    path.write_bytes(blob)
    return path


class TestKernelScan(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_finds_all_three_dtypes(self):
        path = _metallib(self.tmp, ['float16', 'bfloat16', 'float32'])
        self.assertEqual(mp.kernel_variants(path),
                         {'float16', 'bfloat16', 'float32'})

    def test_detects_the_missing_float32_instantiation(self):
        """The exact shape of the ISSUE-MLX.md crash: fp16 and bf16 only."""
        path = _metallib(self.tmp, ['float16', 'bfloat16'])
        variants = mp.kernel_variants(path)
        self.assertEqual(variants, {'float16', 'bfloat16'})
        self.assertNotIn('float32', variants)

    def test_no_gather_kernels_at_all(self):
        path = self.tmp / 'mlx.metallib'
        path.write_bytes(b'\x00' * 1024)
        self.assertEqual(mp.kernel_variants(path), set())

    def test_check_kernel_reports_broken_build(self):
        path = _metallib(self.tmp, ['float16', 'bfloat16'])
        saved, mp.metallib_path = mp.metallib_path, lambda: path
        try:
            ok, detail = mp.check_kernel()
        finally:
            mp.metallib_path = saved
        self.assertFalse(ok)
        self.assertEqual(detail['gather_kernel_dtypes'], ['bfloat16', 'float16'])

    def test_check_kernel_cannot_tell_when_there_are_no_kernels(self):
        path = self.tmp / 'mlx.metallib'
        path.write_bytes(b'\x00' * 512)
        saved, mp.metallib_path = mp.metallib_path, lambda: path
        try:
            with self.assertRaises(mp.Unavailable):
                mp.check_kernel()
        finally:
            mp.metallib_path = saved


class TestVersionParsing(unittest.TestCase):
    def test_orders_the_versions_that_matter(self):
        self.assertLess(mp._parse_version('0.31.1'), mp.KERNEL_FIXED_IN)
        self.assertGreaterEqual(mp._parse_version('0.31.2'), mp.KERNEL_FIXED_IN)
        self.assertLess(mp._parse_version('0.31.2'), mp.REQUIREMENTS_FLOOR)
        self.assertGreaterEqual(mp._parse_version('0.32.2'), mp.REQUIREMENTS_FLOOR)

    def test_tolerates_dev_and_short_versions(self):
        self.assertEqual(mp._parse_version('0.33'), (0, 33, 0))
        self.assertEqual(mp._parse_version('0.33.0.dev20260901'), (0, 33, 0))
        self.assertEqual(mp._parse_version('1.0.0rc1'), (1, 0, 0))


class TestPreflightReport(unittest.TestCase):
    """The three outcomes, assembled without touching a real mlx install."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self._saved = (mp.platform.system, mp.mlx_version, mp.metallib_path)

    def tearDown(self):
        mp.platform.system, mp.mlx_version, mp.metallib_path = self._saved
        self._tmp.cleanup()

    def _arrange(self, version, dtypes):
        path = _metallib(self.tmp, dtypes)
        mp.platform.system = lambda: 'Darwin'
        mp.mlx_version = lambda: version
        mp.metallib_path = lambda: path

    def test_good_build_passes(self):
        self._arrange('0.32.2', ['float16', 'bfloat16', 'float32'])
        report = mp.preflight()
        self.assertTrue(report['ok'])
        self.assertEqual(report['reasons'], [])
        self.assertEqual(report['warnings'], [])

    def test_kernel_missing_fails_even_on_a_new_version(self):
        self._arrange('0.99.0', ['float16', 'bfloat16'])
        report = mp.preflight()
        self.assertFalse(report['ok'])
        self.assertIn('float32', report['reasons'][0])

    def test_old_version_fails(self):
        self._arrange('0.31.1', ['float16', 'bfloat16'])
        report = mp.preflight()
        self.assertFalse(report['ok'])
        self.assertEqual(len(report['reasons']), 2)   # version and kernel

    def test_between_the_floors_warns_but_passes(self):
        self._arrange('0.31.2', ['float16', 'bfloat16', 'float32'])
        report = mp.preflight()
        self.assertTrue(report['ok'])
        self.assertEqual(len(report['warnings']), 1)

    def test_non_darwin_is_not_applicable(self):
        mp.platform.system = lambda: 'Linux'
        with self.assertRaises(mp.Unavailable):
            mp.preflight()


if __name__ == '__main__':
    unittest.main()
