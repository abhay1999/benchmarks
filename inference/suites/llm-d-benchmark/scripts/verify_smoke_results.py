#!/usr/bin/env python3
"""Validate the evidence contract for one smoke-test treatment."""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path
from typing import Any

import yaml


REPORT_GLOB = "benchmark_report_v0.2,*_stage_*_lifecycle_metrics.json.yaml"


def nested(document: dict[str, Any], *keys: str) -> Any:
    value: Any = document
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            raise ValueError(f"missing report field: {'.'.join(keys)}")
        value = value[key]
    return value


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        document = yaml.safe_load(stream) or {}
    if not isinstance(document, dict):
        raise ValueError(f"expected a mapping in {path}")
    return document


def require_file(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"missing or empty smoke-test artifact: {path}")


def validate(args: argparse.Namespace) -> None:
    campaign = args.campaign.resolve()
    manifest = load_yaml(campaign / "campaign-manifest.yaml")
    if manifest.get("campaign_id") != campaign.name:
        raise ValueError("campaign manifest ID does not match its directory")
    identity = manifest.get("identity", {})
    if identity.get("cluster_provider") != "gke":
        raise ValueError("smoke-test campaign did not record the GKE provider")
    if identity.get("accelerator_type") != args.accelerator:
        raise ValueError("smoke-test accelerator does not match the requested phase")
    repetitions = (
        manifest.get("treatments", {})
        .get(args.treatment, {})
        .get("repetitions", {})
    )
    if "1" not in repetitions:
        raise ValueError("smoke-test manifest has no repetition 1")

    evidence = campaign / "runs" / args.treatment / "repetition-1"
    for name in (
        "benchmark-scenario.yaml",
        "config.yaml",
        "run_metadata.yaml",
        "inference-perf-stdout.log",
        "summary_lifecycle_metrics.json",
        "per_request_lifecycle_metrics.json.gz",
    ):
        require_file(evidence / name)
    with gzip.open(evidence / "per_request_lifecycle_metrics.json.gz", "rb") as stream:
        if not stream.read(1):
            raise ValueError("per-request evidence archive is empty")

    observed_rates: set[float] = set()
    reports = sorted(evidence.glob(REPORT_GLOB))
    if len(reports) < 2:
        raise ValueError(f"expected at least two stage reports; found {len(reports)}")
    for report in reports:
        document = load_yaml(report)
        standardized = nested(document, "scenario", "load", "standardized")
        observed_rates.add(float(nested(standardized, "rate_qps")))
        requests = nested(
            document,
            "results",
            "request_performance",
            "aggregate",
            "requests",
        )
        total = float(nested(requests, "total"))
        failures = float(nested(requests, "failures"))
        if total <= 0 or failures != 0:
            raise ValueError(
                f"smoke-test stage failed: {report.name}: "
                f"total={total:g}, failures={failures:g}"
            )
    expected_rates = {1.0, 2.0}
    if not expected_rates.issubset(observed_rates):
        raise ValueError(
            f"smoke-test rates are incomplete: expected {sorted(expected_rates)}, "
            f"observed {sorted(observed_rates)}"
        )

    runtime_metrics = evidence / "runtime-metrics"
    if not runtime_metrics.is_dir() or not any(
        path.is_file() for path in runtime_metrics.rglob("*")
    ):
        raise ValueError("runtime metrics evidence is missing")
    if args.accelerator == "gpu":
        release = load_yaml(evidence / "gpu-release.yaml")
        if release.get("policy") != "after-load":
            raise ValueError("GPU smoke test did not use after-load release")
        if int(release.get("accelerators_released", 0)) < 1:
            raise ValueError("GPU smoke test did not record accelerator release")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--campaign", required=True, type=Path)
    parser.add_argument("--treatment", required=True)
    parser.add_argument("--accelerator", required=True, choices=("sim", "gpu"))
    args = parser.parse_args()
    validate(args)
    print(f"smoke evidence verified: {args.campaign}")


if __name__ == "__main__":
    main()
