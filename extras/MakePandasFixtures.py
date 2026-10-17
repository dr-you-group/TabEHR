"""Generate the expected values of the MedRep quantile logic, using pandas.

    python extras/MakePandasFixtures.py

Writes two CSV fixtures that tests/testthat/test-quantiles.R checks the ported
logic against. The point is to pin down what create_trajectory.py actually does,
including its edge cases, so the SQL port can be compared with something other
than a reading of the code:

  quantile_values.csv  per (group, j): the boundary pandas computes with
                       x.quantile(np.linspace(0, 1, 11)), plus the sorted
                       values of the group, so any implementation can be run
                       against the same input
  quantile_bins.csv    per (group, value): the bin
                       max(0, bisect_left(q, value) - 1) assigns

The groups deliberately include the awkward cases: a tiny group, a group with
many repeated values so the boundary array itself repeats, a heavily skewed
group, and values below, at and above every boundary.
"""

import bisect
import csv
import os

import numpy as np
import pandas as pd

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                    "tests", "testthat")
QUANTILE_COUNT = 10


def groups():
    rng = np.random.default_rng(20261015)
    return {
        # Exactly the (concept, unit) >= 10 threshold.
        "ten_values": [float(v) for v in range(10)],
        # Repeats, so several boundaries are identical and the bisect_left
        # behaviour on ties is what decides the bin.
        "many_ties": [0.0] * 40 + [1.0] * 40 + [5.0] * 20,
        # Skewed, like a lab with a long tail.
        "skewed": list(np.round(rng.lognormal(mean=1.0, sigma=1.5, size=500), 4)),
        # Negative and positive, like a base excess.
        "signed": list(np.round(rng.normal(loc=0.0, scale=7.0, size=137), 3)),
        # Large n, to exercise the (n - 1) * p arithmetic.
        "large": list(np.round(rng.normal(loc=120.0, scale=18.0, size=10001), 2)),
        # Two values only.
        "two_values": [2.5, 7.5],
        # One value: every boundary is the same number.
        "one_value": [42.0],
    }


def main():
    # pandas Series.quantile(q) calls np.percentile(x, q * 100), and numpy
    # divides by 100 again; that round trip is not the identity on a double, so
    # record the probability the boundaries were actually computed at.
    probabilities = np.linspace(0, 1, QUANTILE_COUNT + 1) * 100 / 100

    value_rows = []
    bin_rows = []
    for name, values in groups().items():
        series = pd.Series(values, dtype="float64")
        boundaries = series.quantile(probabilities).to_numpy()
        ordered = sorted(float(v) for v in values)

        for j, boundary in enumerate(boundaries):
            value_rows.append(
                {
                    "group": name,
                    "n": len(values),
                    "j": j,
                    # 17 significant digits round-trips a float64 exactly.
                    "probability": repr(float(probabilities[j])),
                    "boundary": repr(float(boundary)),
                    "values": " ".join(repr(v) for v in ordered),
                }
            )

        # Probe values: every boundary itself, just below and just above it, and
        # points outside the range.
        probes = set()
        for boundary in boundaries:
            probes.update([float(boundary)])
            probes.update([float(boundary) - 1e-9, float(boundary) + 1e-9])
        probes.update([float(ordered[0]) - 10.0, float(ordered[-1]) + 10.0])
        for value in sorted(probes):
            assigned = max(0, bisect.bisect_left(list(boundaries), value) - 1)
            bin_rows.append(
                {
                    "group": name,
                    "value": repr(value),
                    "expected_bin": assigned,
                }
            )

    with open(os.path.join(HERE, "quantile_values.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["group", "n", "j", "probability", "boundary", "values"]
        )
        writer.writeheader()
        writer.writerows(value_rows)

    with open(os.path.join(HERE, "quantile_bins.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["group", "value", "expected_bin"])
        writer.writeheader()
        writer.writerows(bin_rows)

    print(f"pandas {pd.__version__}, numpy {np.__version__}")
    print(f"wrote {len(value_rows)} boundary rows and {len(bin_rows)} bin rows")
    print("linspace:", " ".join(repr(float(p)) for p in probabilities))


if __name__ == "__main__":
    main()
