"""The conversation booster must decline a corpus it can only memorise (#790).

The 2026-08 release fine-tuned on **17** conversations for 300 iterations at
batch 1x8 — about 140 epochs over the same seventeen rows — and the README
describes that booster as producing the final model.

It is applied last and fused into the release, so it is the most consequential
stage in the pipeline and it had the least data behind it. No downstream gate
makes 17 rows safe: a model that has memorised its corpus passes a finite-weight
check and a small holdout comfortably. So the floor is a refusal to run, not a
quality threshold to tune.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from train_utils import (  # noqa: E402
    MIN_CONVERSATIONS_FOR_BOOSTER,
    conversation_corpus_verdict,
)


class TestConversationCorpusFloor(unittest.TestCase):

    def test_the_shipped_corpus_is_refused(self):
        reason = conversation_corpus_verdict(17, iters=300, batch_size=8)
        self.assertIsNotNone(reason, 'the corpus this issue is about must be refused')
        self.assertIn('17 conversations', reason)
        # The epoch count is what makes 17 alarming rather than merely small,
        # so the message carries it rather than leaving the reader to multiply.
        self.assertIn('epochs', reason)

    def test_the_epoch_figure_is_the_real_one(self):
        # 300 x 8 / 17 = 141. The issue says "roughly 140 epochs"; if this
        # arithmetic ever drifts the message stops being evidence.
        self.assertIn('141 epochs',
                      conversation_corpus_verdict(17, iters=300, batch_size=8))

    def test_at_the_floor_it_runs(self):
        self.assertIsNone(conversation_corpus_verdict(MIN_CONVERSATIONS_FOR_BOOSTER))
        self.assertIsNotNone(conversation_corpus_verdict(MIN_CONVERSATIONS_FOR_BOOSTER - 1))

    def test_floor_is_configurable(self):
        self.assertIsNone(conversation_corpus_verdict(50, minimum=50))
        self.assertIsNotNone(conversation_corpus_verdict(50, minimum=200))

    def test_empty_corpus_is_refused_without_an_invented_epoch_count(self):
        reason = conversation_corpus_verdict(0, iters=300, batch_size=8)
        self.assertIsNotNone(reason)
        # No ZeroDivisionError, and no epoch figure claimed for an empty set.
        self.assertNotIn('epochs', reason)

    def test_singular_reads_correctly(self):
        self.assertIn('1 conversation is', conversation_corpus_verdict(1))

    def test_missing_iteration_detail_still_refuses(self):
        reason = conversation_corpus_verdict(17)
        self.assertIsNotNone(reason)
        self.assertNotIn('epochs', reason)

    def test_unparseable_count_is_not_guessed_at(self):
        self.assertIsNone(conversation_corpus_verdict(None))
        self.assertIsNone(conversation_corpus_verdict('many'))


if __name__ == '__main__':
    unittest.main()
