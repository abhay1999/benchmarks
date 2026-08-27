from __future__ import annotations

import argparse
import gzip
from pathlib import Path
import sys
import tempfile
import unittest

import yaml


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from verify_smoke_results import validate  # noqa: E402


def report(stage: int, rate: float, failures: int = 0) -> dict:
    return {
        "scenario": {"load": {"standardized": {"stage": stage, "rate_qps": rate}}},
        "results": {
            "request_performance": {
                "aggregate": {"requests": {"total": 10, "failures": failures}}
            }
        },
    }


class VerifySmokeResultsTest(unittest.TestCase):
    def create_campaign(self, root: Path, accelerator: str = "sim") -> Path:
        campaign = root / f"test-smoke-{accelerator}"
        evidence = campaign / "runs" / "agentgateway-gateway" / "repetition-1"
        evidence.mkdir(parents=True)
        manifest = {
            "campaign_id": campaign.name,
            "identity": {"cluster_provider": "gke", "accelerator_type": accelerator},
            "treatments": {
                "agentgateway-gateway": {"repetitions": {"1": {}}}
            },
        }
        (campaign / "campaign-manifest.yaml").write_text(
            yaml.safe_dump(manifest), encoding="utf-8"
        )
        for name in (
            "benchmark-scenario.yaml",
            "config.yaml",
            "run_metadata.yaml",
            "inference-perf-stdout.log",
            "summary_lifecycle_metrics.json",
        ):
            (evidence / name).write_text("evidence\n", encoding="utf-8")
        with gzip.open(evidence / "per_request_lifecycle_metrics.json.gz", "wb") as stream:
            stream.write(b"{}")
        runtime = evidence / "runtime-metrics"
        runtime.mkdir()
        (runtime / "sample.txt").write_text("metric 1\n", encoding="utf-8")
        for stage, rate in enumerate((1, 2)):
            path = evidence / (
                f"benchmark_report_v0.2,_agentgateway-gateway_stage_{stage}_"
                "lifecycle_metrics.json.yaml"
            )
            path.write_text(yaml.safe_dump(report(stage, rate)), encoding="utf-8")
        if accelerator == "gpu":
            (evidence / "gpu-release.yaml").write_text(
                yaml.safe_dump({"policy": "after-load", "accelerators_released": 1}),
                encoding="utf-8",
            )
        return campaign

    def args(self, campaign: Path, accelerator: str = "sim") -> argparse.Namespace:
        return argparse.Namespace(
            campaign=campaign,
            treatment="agentgateway-gateway",
            accelerator=accelerator,
        )

    def test_accepts_complete_sim_and_gpu_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            validate(self.args(self.create_campaign(root, "sim"), "sim"))
            validate(self.args(self.create_campaign(root, "gpu"), "gpu"))

    def test_rejects_request_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            campaign = self.create_campaign(Path(directory))
            report_path = next(campaign.rglob("*stage_1_lifecycle_metrics.json.yaml"))
            report_path.write_text(yaml.safe_dump(report(1, 2, failures=1)), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "stage failed"):
                validate(self.args(campaign))


if __name__ == "__main__":
    unittest.main()
