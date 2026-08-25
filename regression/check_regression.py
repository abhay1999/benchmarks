#!/usr/bin/env python3
"""Fails if a benchmark run regressed past a threshold vs its stored baseline.

Reads the p99 request latency out of a llm-d-benchmark report (same
results.request_performance.aggregate.latency.request_latency.p99 path
cross_treatment.py uses), compares it against a stored baseline.json for
that scenario, and exits non-zero if it got worse by more than the
threshold. Meant to run as a CI step after a benchmark run.
"""

import argparse
import json
import sys
from pathlib import Path

METRIC_PATH = ["results", "request_performance", "aggregate", "latency", "request_latency", "p99"]

def extract_metric(report_path: Path) -> float:
    try:
        import yaml
        with open(report_path) as f:
            report = yaml.safe_load(f)
        value = report
        for key in METRIC_PATH:
            value = value[key]
        return float(value)
    except ImportError:
        import re
        with open(report_path) as f:
            content = f.read()
        match = re.search(r"p99:\s*([0-9.eE+-]+)", content)
        if match:
            return float(match.group(1))
        raise RuntimeError("Could not extract p99 metric from report")


def load_baseline(baseline_path: Path) -> dict:
    with open(baseline_path) as f:
        return json.load(f)


def check(current: float, baseline: float, threshold: float) -> tuple[bool, str]:
    pct_change = (current - baseline) / baseline
    verdict = "REGRESSED" if pct_change > threshold else "OK"
    message = (
        f"[{verdict}] p99 request latency: {baseline * 1000:.2f}ms -> {current * 1000:.2f}ms "
        f"({pct_change:+.1%}). Threshold: {threshold:.0%}"
    )
    return pct_change > threshold, message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path, help="benchmark_report_v0.2*.yaml from a run")
    parser.add_argument("--baseline", required=True, type=Path, help="baseline.json for this scenario")
    parser.add_argument("--threshold", type=float, default=0.10, help="regression threshold (default: 0.10 = 10%%)")
    args = parser.parse_args()

    current = extract_metric(args.report)
    baseline = load_baseline(args.baseline)

    regressed, message = check(current, baseline["p99_request_latency_s"], args.threshold)
    print(message)
    sys.exit(1 if regressed else 0)


if __name__ == "__main__":
    main()
