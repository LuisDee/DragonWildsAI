"""How much a count says: is a rate known, did a change move it, and how many trials would show it.

  .venv\\Scripts\\python.exe -m tools.ab one 5 5            # 5 of 5: the rate with its 95 % interval
  .venv\\Scripts\\python.exe -m tools.ab two 8 43 11 16     # before 8 of 43, after 11 of 16: both rates and Fisher's p
  .venv\\Scripts\\python.exe -m tools.ab need 0.36 0.15     # trials per side to tell 36 % from 15 % (5 %, power 80 %)

Why (docs/RETRO-2026-11-17-session.md): a slope fix was judged on one window of 5 trials, and 5 of 5 only says the pass
rate is above about 57 %. A window states what it expects to move and how many trials that takes BEFORE it runs.
Stdlib only. Counts of things inside one trial (paths, jumps) are not independent: read their p as a lower bound.
"""
from __future__ import annotations

import argparse
import math
import sys
from statistics import NormalDist

Z95 = NormalDist().inv_cdf(0.975)


def wilson(k: int, n: int, z: float = Z95) -> tuple[float, float]:
    """The Wilson score interval of k of n (Wilson 1927): sound at 0 of n and n of n, where the plain one is not."""
    if n <= 0:
        return 0.0, 1.0
    p, d = k / n, 1 + z * z / n
    mid, half = (p + z * z / (2 * n)) / d, z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (0.0 if k == 0 else max(0.0, mid - half)), (1.0 if k == n else min(1.0, mid + half))


def fisher(k1: int, n1: int, k2: int, n2: int) -> float:
    """Fisher's exact test, two-sided: the chance of a split at least this unlikely if both sides had one rate."""
    k, n = k1 + k2, n1 + n2

    def pr(x: int) -> float:
        return math.comb(n1, x) * math.comb(n2, k - x) / math.comb(n, k)

    here = pr(k1)
    return min(1.0, sum(p for x in range(max(0, k - n2), min(k, n1) + 1) if (p := pr(x)) <= here * (1 + 1e-9)))


def need(p0: float, p1: float, alpha: float = 0.05, power: float = 0.8) -> int:
    """Trials per side for a two-sided test of two rates (the usual normal approximation, pooled under the null)."""
    if p0 == p1:
        return sys.maxsize
    za, zb, pb = NormalDist().inv_cdf(1 - alpha / 2), NormalDist().inv_cdf(power), (p0 + p1) / 2
    top = za * math.sqrt(2 * pb * (1 - pb)) + zb * math.sqrt(p0 * (1 - p0) + p1 * (1 - p1))
    return math.ceil(top * top / ((p0 - p1) ** 2))


def _row(k: int, n: int) -> str:
    lo, hi = wilson(k, n)
    return f"{k} of {n} = {100 * k / n:.0f} % (95 %: {100 * lo:.0f} to {100 * hi:.0f} %)"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("one")
    o.add_argument("k", type=int)
    o.add_argument("n", type=int)
    t = sub.add_parser("two")
    for name in ("k1", "n1", "k2", "n2"):
        t.add_argument(name, type=int)
    nd = sub.add_parser("need")
    nd.add_argument("p0", type=float)
    nd.add_argument("p1", type=float)
    nd.add_argument("--power", type=float, default=0.8)
    a = ap.parse_args(argv)
    if a.cmd == "one":
        print(_row(a.k, a.n))
    elif a.cmd == "two":
        p = fisher(a.k1, a.n1, a.k2, a.n2)
        print(f"before: {_row(a.k1, a.n1)}\nafter:  {_row(a.k2, a.n2)}\nFisher's exact p = {p:.4f}: "
              + ("a difference this size is unlikely by chance" if p < 0.05 else "not told apart at these counts"))
    else:
        print(f"{need(a.p0, a.p1, power=a.power)} trials per side to tell {100 * a.p0:.0f} % from {100 * a.p1:.0f} % "
              f"(two-sided 5 %, power {100 * a.power:.0f} %)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
