#!/usr/bin/env python3
"""Writes/overwrites a scenario's baseline.json from a benchmark report.

Meant to be run by hand after a release is cut and the numbers have been
reviewed - not automatic. See check_regression.py for how this gets used.
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from check_regression import METRIC_PATH, extract_metric


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path, help="benchmark_report_v0.2*.yaml to baseline from")
    parser.add_argument("--scenario", required=True, help="scenario name, e.g. agentgateway-decode-only")
    parser.add_argument("--out", required=True, type=Path, help="baseline.json path to write")
    args = parser.parse_args()

    p99 = extract_metric(args.report)
    baseline = {
        "scenario": args.scenario,
        "p99_request_latency_s": p99,
        "metric_path": ".".join(METRIC_PATH),
        "source_report": str(args.report),
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(baseline, f, indent=2)
        f.write("\n")

    print(f"wrote baseline for {args.scenario}: p99={p99 * 1000:.2f}ms -> {args.out}")


if __name__ == "__main__":
    main()
