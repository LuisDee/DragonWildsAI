"""tools/ab.py: what a count says (Wilson interval, Fisher's exact test, trials needed)."""
from __future__ import annotations

from tools import ab


def test_five_of_five_leaves_the_rate_open_down_to_about_57_percent():
    lo, hi = ab.wilson(5, 5)
    assert 0.56 < lo < 0.58 and hi == 1.0
    lo, hi = ab.wilson(0, 10)
    assert lo == 0.0 and 0.27 < hi < 0.29


def test_fisher_against_known_values():
    assert abs(ab.fisher(3, 4, 1, 4) - 0.4857) < 1e-3      # the tea-tasting table
    assert abs(ab.fisher(1, 10, 1, 10) - 1.0) < 1e-9       # the same on both sides
    assert ab.fisher(8, 43, 11, 16) < 0.001                # window s31's jumps against the two before it
    assert ab.fisher(6, 38, 2, 11) > 0.5                   # its 40 to 80 cm walks: no difference shown


def test_trials_needed_grow_as_the_rates_close():
    assert ab.need(0.36, 0.15) < ab.need(0.36, 0.30)
    assert 60 < ab.need(0.36, 0.15) < 80
    assert ab.main(["two", "8", "43", "11", "16"]) == 0 and ab.main(["one", "5", "5"]) == 0 and ab.main(["need", "0.6", "0.9"]) == 0
