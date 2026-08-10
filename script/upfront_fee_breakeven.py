#!/usr/bin/env python3
"""How many days a looper needs to re-earn the upfront fee.

fee = rate * (L - 1) * period / year        (% of equity, debt = (L - 1) * equity)
carry = yield * L - rate * (L - 1)          (net APR on equity)
breakeven = 365 * fee / carry

Usage: ./upfront_fee_breakeven.py --yield 5.6 --rate 5.3 --period 1
"""

import argparse

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument("--yield", dest="y", type=float, default=10.0, help="collateral yield, %% APR (default 10)")
p.add_argument("--rate", type=float, default=8.0, help="borrow rate, %% APR (default 8)")
p.add_argument("--period", type=float, default=7.0, help="upfront interest period, days (default 7)")
p.add_argument("--leverage", type=float, nargs="*", default=[2, 5, 10, 20], help="leverage multiples (default 2 5 10 20)")
a = p.parse_args()

print(f"collateral yield {a.y}%, borrow rate {a.rate}%, upfront period {a.period} days")
for L in a.leverage:
    fee = a.rate * (L - 1) * a.period / 365  # % of equity
    carry = a.y * L - a.rate * (L - 1)  # % APR on equity
    if carry <= 0:
        print(f"  {L:>4.0f}x  negative carry, never")
        continue
    print(f"  {L:>4.0f}x  net APR {carry:5.2f}%  breakeven {365 * fee / carry:5.1f} days")
