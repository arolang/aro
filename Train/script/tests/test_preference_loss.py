"""Unit tests for the pure-python parts of preference_loss.py (issue #413).

The MLX training loop itself needs a loaded model; these tests cover data
loading, tokenization boundaries, and the loss math on toy arrays (the loss
tests run only when mlx is installed, i.e. on Apple Silicon).
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from preference_loss import (  # noqa: E402
    load_pairs, tokenize_pair, _completion_content, build_parser,
)


class FakeTokenizer:
    """Whitespace tokenizer with a chat template shaped like Qwen's."""
    eos_token = '<eos>'

    def apply_chat_template(self, messages, tokenize=False,
                            add_generation_prompt=False):
        parts = [f'[{m["role"]}] {m["content"]}' for m in messages]
        text = ' '.join(parts)
        if add_generation_prompt:
            text += ' [assistant]'
        return text

    def encode(self, text, add_special_tokens=True):
        return [hash(w) % 50000 for w in text.split()]


def _pair(instr='write code', chosen='valid aro code here',
          rejected='broken code'):
    return {
        'prompt': [{'role': 'system', 'content': 'sys'},
                   {'role': 'user', 'content': instr}],
        'chosen': [{'role': 'assistant', 'content': chosen}],
        'rejected': [{'role': 'assistant', 'content': rejected}],
    }


class TestData(unittest.TestCase):
    def test_load_pairs(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'train.jsonl'
            with open(p, 'w') as f:
                f.write(json.dumps(_pair()) + '\n')
                f.write('\n')                            # blank line skipped
                f.write(json.dumps({'prompt': []}) + '\n')  # incomplete -> kept out
            pairs = load_pairs(p)
            self.assertEqual(len(pairs), 1)

    def test_completion_content(self):
        self.assertEqual(_completion_content(
            [{'role': 'assistant', 'content': 'x'}]), 'x')
        self.assertEqual(_completion_content('raw'), 'raw')
        self.assertEqual(_completion_content([]), '')
        self.assertEqual(_completion_content(
            [{'role': 'assistant', 'content': ''}]), '')


class TestTokenizePair(unittest.TestCase):
    def setUp(self):
        self.tok = FakeTokenizer()

    def test_basic(self):
        res = tokenize_pair(self.tok, _pair(), max_seq_length=4096)
        self.assertIsNotNone(res)
        chosen, rejected, plen = res
        self.assertGreater(len(chosen), plen)
        self.assertGreater(len(rejected), plen)
        self.assertEqual(chosen[:plen], rejected[:plen])   # shared prompt

    def test_empty_rejected_gets_eos(self):
        # Empty-content penalty pairs (issue #414): rejected == "" must still
        # produce >= 1 completion token (the EOS), not be skipped.
        res = tokenize_pair(self.tok, _pair(rejected=''), max_seq_length=4096)
        self.assertIsNotNone(res)
        _, rejected, plen = res
        self.assertEqual(len(rejected) - plen, 1)

    def test_oversized_skipped(self):
        long_pair = _pair(chosen='word ' * 5000)
        self.assertIsNone(tokenize_pair(self.tok, long_pair, max_seq_length=64))


class TestCli(unittest.TestCase):
    def test_defaults(self):
        args = build_parser().parse_args([
            '--model', 'm', '--data', 'd', '--adapter-path', 'a'])
        self.assertEqual(args.iters, 200)
        self.assertEqual(args.lora_rank, 8)
        self.assertEqual(args.weight_decay, 0.01)
        self.assertEqual(args.lr_schedule, 'cosine')
        self.assertGreater(args.beta, 0)
        self.assertGreater(args.margin, 0)


class TestLossMath(unittest.TestCase):
    """Numeric checks of the hinge — requires mlx (Apple Silicon)."""

    def setUp(self):
        try:
            import mlx.core  # noqa: F401
        except ImportError:
            self.skipTest('mlx not installed')

    def test_hinge_zero_when_gap_exceeds_margin(self):
        import mlx.core as mx
        margin = 0.5
        lp_chosen, lp_rejected = mx.array(-0.2), mx.array(-2.0)
        hinge = mx.maximum(0.0, margin - (lp_chosen - lp_rejected))
        self.assertEqual(float(hinge), 0.0)

    def test_hinge_positive_when_rejected_preferred(self):
        import mlx.core as mx
        margin = 0.5
        lp_chosen, lp_rejected = mx.array(-2.0), mx.array(-0.2)
        hinge = mx.maximum(0.0, margin - (lp_chosen - lp_rejected))
        self.assertAlmostEqual(float(hinge), 0.5 + 1.8, places=5)

    def test_completion_nll_masks_prompt(self):
        """_completion_nll must ignore prompt positions entirely."""
        import mlx.core as mx
        from preference_loss import _completion_nll

        class ToyModel:
            """Uniform logits -> NLL == log(V) regardless of tokens."""
            def __call__(self, inputs):
                return mx.zeros((*inputs.shape, 7))  # vocab of 7

        import math
        toks = mx.array([1, 2, 3, 4, 5, 6])
        nll = _completion_nll(ToyModel(), toks, prompt_len=3)
        self.assertAlmostEqual(float(nll), math.log(7), places=5)


if __name__ == '__main__':
    unittest.main()
