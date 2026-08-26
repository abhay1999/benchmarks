# Inference benchmarks

The inference benchmark tooling runs independently selectable treatments,
retains their native evidence in a shared campaign, and generates publishable
Markdown, PNG, and CSV comparisons. Prism-compatible Benchmark Report v0.2
documents remain available in each treatment's evidence bundle.

PR #1 intentionally migrates tooling only. Curated reports from the original
agentgateway repository change are not part of this migration and will be
published separately with their supporting evidence.

## Layout

```text
inference/
  run-benchmark.sh
  provisioning/
    gke/                  # gcloud-based GKE infrastructure lifecycle
  suites/
    llm-d-benchmark/
      scenarios/
      workloads/
      scripts/
      tests/
  reporting/
    adapters/
    common/
    tests/
    generate.py
  results/                 # ignored local campaign data
  reports/                 # curated reports suitable for committing
```

`llm-d-benchmark` is currently the implemented execution suite. The suite
boundary allows the EPP performance harness or another inference benchmark to
be added without creating another top-level wrapper.

## Treatments and campaigns

Every invocation runs exactly one treatment. A campaign groups treatments and
repetitions whose inference backend, workload, and infrastructure must match.

| `BENCHMARK_TREATMENT` | Request path |
|---|---|
| `service` | Kubernetes Service directly to vLLM |
| `agentgateway-standalone` | agentgateway in the standalone EPP topology |
| `agentgateway-gateway` | agentgateway on Kubernetes with EPP |
| `envoy-standalone` | Envoy sidecar in the standalone EPP topology |

Required variables:

| Variable | Purpose |
|---|---|
| `BENCHMARK_TREATMENT` | One treatment from the table above |
| `BENCHMARK_CAMPAIGN_ID` | Shared lowercase identifier for comparable runs |

`BENCHMARK_REPETITION` defaults to `1`. Use `1`, `2`, and `3` for a
three-repetition publication campaign. The wrapper rejects a treatment whose
campaign identity differs from existing runs.

## Local simulator example

### Prerequisites

`make benchmark` creates the Kind cluster when it does not already exist. The
`service` and standalone treatments do not require Gateway API CRDs. Install
the Gateway API and Inference Extension CRDs before running
`agentgateway-gateway`:

```bash
make kind-create
make gw-api-crds
make gie-crds
```

Run the Service treatment:

```bash
BENCHMARK_TREATMENT=service \
BENCHMARK_CAMPAIGN_ID=local-sim \
make benchmark
```

Then run standalone agentgateway with the same inputs:

```bash
BENCHMARK_TREATMENT=agentgateway-standalone \
BENCHMARK_CAMPAIGN_ID=local-sim \
make benchmark
```

The Kind provider is the default. It always imports the selected agentgateway
image archive into the cluster so a mutable local tag cannot silently reuse an
older node image.

## GKE smoke campaigns

Use the smoke targets to validate provisioning, Gateway API routing, EPP,
agentgateway, inference-perf, evidence collection, and cleanup before paying
for a full campaign:

```bash
# Safe first phase: the provisioned GPU pool remains at zero.
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-smoke-sim

# Explicitly billable: one Spot a3-highgpu-2g node and a small vLLM model.
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-smoke-gpu

# Run the GPU phase only after simulator evidence validation succeeds.
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-smoke-all
```

The checked-in smoke workload uses two 20-second constant-load stages at 1 and
2 QPS. The simulator phase uses one inference-sim replica. The GPU phase uses
one `facebook/opt-125m` vLLM replica on one Spot node and releases the GPU pool
immediately after traffic completes. It is an end-to-end validation workload,
not a performance result.

The smoke model is public. The smoke orchestrator uses the configured shared
HF Secret when present, creates it from `HF_TOKEN` when supplied, and otherwise
continues unauthenticated. Normal GKE campaigns still require the Secret by
default; only the smoke path sets `BENCHMARK_HF_TOKEN_REQUIRED=false`.

Each phase receives a separate campaign ID because simulator and GPU results
are not comparable. The verifier requires successful stage reports,
per-request evidence, runtime metrics, and—for the GPU phase—after-load release
evidence. Any failure or interruption runs the campaign finalizer and returns
the GPU pool to zero. `BENCHMARK_GKE_CLUSTER_LIFECYCLE=destroy` additionally
removes the provisioner-owned cluster after cleanup; `retain` is the default.

These single-treatment campaigns do not generate comparison Markdown or PNG
reports. A comparison report still requires two compatible treatments.

## Published optimized-baseline profile

Use the upstream workload variant when producing a report comparable to the
llm-d Qwen3-32B/H100 optimized-baseline report. It preserves the Poisson load
ladder, 300-second request timeout, shared-prefix shape, and per-request output.

There is an important historical-version nuance. The published v0.9 report's
calibration matrix records vLLM v0.23.0, while the image overlay currently
reachable through the mutable v0.9 guide selects v0.26.0. Select
`BENCHMARK_REFERENCE_PROFILE=optimized-baseline-qwen3-32b-h100-v0.9` to pin
the report-era vLLM version, router/EPP v0.9.0, model-server command, resources,
and topology. The normal wrapper default remains vLLM v0.27.1.

The intended topology is:

- Qwen/Qwen3-32B
- vLLM v0.23.0 with the v0.9 reference profile (v0.27.1 otherwise)
- 8 decode replicas
- TP=2
- 16 H100 GPUs
- 6,000-token shared system prompt
- 1,200-token question
- 1,000-token requested output
- rates from 3 through 60 QPS

Common GKE settings for each treatment are:

```bash
BENCHMARK_CLUSTER_PROVIDER=gke \
BENCHMARK_KUBE_CONTEXT=<context> \
BENCHMARK_ACCELERATOR_TYPE=gpu \
BENCHMARK_ACCELERATOR_MODEL=h100 \
BENCHMARK_BACKEND_TYPE=vllm \
BENCHMARK_SCENARIO=optimized-baseline \
BENCHMARK_ROUTING_POLICY=optimized-baseline \
BENCHMARK_REFERENCE_PROFILE=optimized-baseline-qwen3-32b-h100-v0.9 \
BENCHMARK_WORKLOAD_VARIANT=upstream \
BENCHMARK_REPLICAS=8 \
BENCHMARK_TENSOR_PARALLELISM=2 \
BENCHMARK_ENDPOINT_PATH=internal \
BENCHMARK_MODEL_STORAGE_PROFILE=high-throughput-shared \
BENCHMARK_WORKLOAD_STORAGE_PROFILE=shared \
BENCHMARK_GPU_RELEASE_POLICY=after-load \
BENCHMARK_CAMPAIGN_ID=<campaign-id> \
BENCHMARK_TREATMENT=<treatment> \
make benchmark
```

The reference profile requires agentgateway v1.4.1. The wrapper verifies the
observed vLLM, EPP, and agentgateway pod images before starting traffic.
`BENCHMARK_ENDPOINT_PATH=internal` explicitly supplies the proxy Service
ClusterIP to the harness; this prevents Gateway status from selecting an
external GKE load-balancer address. Use `external` only when the external path
is itself the subject of the experiment.

For a controlled model-server version comparison, use
`BENCHMARK_REFERENCE_PROFILE=optimized-baseline-qwen3-32b-h100-v0.9-vllm-v0.27.1`.
It preserves the historical profile's command, topology, EPP version, and
resources while changing only the vLLM image from v0.23.0 to v0.27.1.

`after-load` provides the largest accelerator cost reduction. The wrapper
stops new runtime-metric samples after inference-perf drains its final stage,
scales the model workloads and GPU node pool to zero, copies the completed
runtime metrics while report generation runs, and lets compressed result
collection, evidence packaging, and teardown continue on CPU nodes. GKE GPU
scenarios declare the NVIDIA accelerator resource explicitly so teardown does
not depend on nodes that were removed. Scale the pool back to the treatment's
required size before starting the next treatment. `after-run` waits for
llm-d-benchmark's run phase to return before releasing the pool, while `never`
leaves release to the campaign finalizer.

The wrapper consumes the stable lifecycle marker proposed in
[llm-d-benchmark#1796](https://github.com/llm-d/llm-d-benchmark/issues/1796).
Until that change is available in the selected upstream revision, it falls
back to inference-perf's final-stage log message. Every release writes
`gpu-release.yaml` into the treatment evidence with the detection source and
timestamps. Fast compressed result collection is enabled by default and can
be disabled with `BENCHMARK_FAST_COLLECT=false` for diagnosis.

Run these treatments for the two primary reports:

```text
service
agentgateway-standalone
agentgateway-gateway
```

### One-command GKE campaign

`benchmark-gke-all` runs the standard optimized-baseline campaign from
infrastructure validation through report generation:

```bash
export BENCHMARK_GKE_PROJECT=your-gcp-project

# Set this only when the cluster intentionally uses the Compute Engine default
# service account instead of the provisioner's dedicated-account default.
export BENCHMARK_GKE_NODE_SERVICE_ACCOUNT=default

# This is unnecessary when the configured Secret already exists.
export HF_TOKEN=hf_your_token

make benchmark-gke-all
```

Unless explicitly overridden, the target:

1. Generates a timestamped `BENCHMARK_CAMPAIGN_ID`.
2. Runs the GKE plan and idempotent provision/verification target.
3. Uses the existing configured Hugging Face Secret, or creates it from
   `HF_TOKEN` without placing the token in a command argument.
4. Scales the GPU pool to eight `a3-highgpu-2g` nodes and verifies 16 H100s.
5. Runs `service`, `agentgateway-standalone`, and `agentgateway-gateway`.
6. Reacquires GPU capacity before each treatment because `after-load` releases
   it after traffic generation.
7. Generates Markdown, PNG, and CSV reports for both Service comparisons.
8. Runs `benchmark-gke-cleanup` on success, failure, or interruption.

The default `BENCHMARK_GKE_CLUSTER_LIFECYCLE=retain` keeps the GKE cluster and
CPU pools for later campaigns. The finalizer still removes campaign resources
and returns the GPU pool to zero. The command logs the generated campaign
identifier and these output directories:

```text
inference/results/llm-d-benchmark/<campaign-id>/
inference/results/llm-d-benchmark/<campaign-id>/generated/
  service-vs-agentgateway-standalone/
  service-vs-agentgateway-gateway/
```

Set `BENCHMARK_CAMPAIGN_ID` before invoking the target when a stable identifier
is required.

For an ephemeral cluster, request destruction explicitly:

```bash
BENCHMARK_GKE_PROJECT=your-gcp-project \
BENCHMARK_GKE_CLUSTER_LIFECYCLE=destroy \
make benchmark-gke-all
```

The `destroy` lifecycle arms the finalizer before provisioning so a partial
provisioning failure is covered. After campaign cleanup succeeds, it deletes
the provisioner-owned cluster and all node pools and verifies that the cluster
is absent. It fails rather than deleting the cluster when PVC, PV,
Filestore, LoadBalancer, or namespace cleanup cannot be verified. Shared
project APIs, IAM, service accounts, networks, and subnetworks are retained.

The one-command workflow is appropriate for unattended or manual runs. It can
take several hours, depending on accelerator availability and model downloads.

### Equivalent manual GKE campaign

The following example provisions or verifies the persistent infrastructure,
creates the shared Hugging Face Secret, runs all three treatments, generates
both reports, and runs the campaign finalizer on success, failure, or
interruption. Run it from the repository root with Bash. The Google Cloud
identity and node service-account IAM prerequisites described in
[GKE benchmark provisioning](provisioning/gke/README.md) must already be
satisfied.

```bash
set -euo pipefail

export BENCHMARK_GKE_PROJECT=your-gcp-project
export BENCHMARK_GKE_LOCATION=us-central1-a
export BENCHMARK_GKE_CLUSTER=agentgateway-benchmark
export BENCHMARK_KUBE_CONTEXT="gke_${BENCHMARK_GKE_PROJECT}_${BENCHMARK_GKE_LOCATION}_${BENCHMARK_GKE_CLUSTER}"
export BENCHMARK_GKE_CPU_NODEPOOL=default-pool
export BENCHMARK_GKE_HARNESS_NODEPOOL=bench-cpu
export BENCHMARK_GKE_GPU_NODEPOOL=gpu-h100
export BENCHMARK_GKE_GPU_MACHINE_TYPE=a3-highgpu-2g
export BENCHMARK_GKE_GPU_ACCELERATOR_TYPE=nvidia-h100-80gb
export BENCHMARK_GKE_GPU_ACCELERATORS_PER_NODE=2
export BENCHMARK_GKE_GPU_TARGET_NODES=8

# Use the dedicated account by default. Set this to "default" only when the
# cluster was intentionally provisioned with the Compute Engine default
# service account.
export BENCHMARK_GKE_NODE_SERVICE_ACCOUNT="agentgateway-benchmark-nodes@${BENCHMARK_GKE_PROJECT}.iam.gserviceaccount.com"

export BENCHMARK_CLUSTER_PROVIDER=gke
export BENCHMARK_ACCELERATOR_TYPE=gpu
export BENCHMARK_ACCELERATOR_MODEL=h100
export BENCHMARK_BACKEND_TYPE=vllm
export BENCHMARK_SCENARIO=optimized-baseline
export BENCHMARK_ROUTING_POLICY=optimized-baseline
export BENCHMARK_REFERENCE_PROFILE=optimized-baseline-qwen3-32b-h100-v0.9
export BENCHMARK_WORKLOAD_VARIANT=upstream
export BENCHMARK_REPLICAS=8
export BENCHMARK_TENSOR_PARALLELISM=2
export BENCHMARK_ENDPOINT_PATH=internal
export BENCHMARK_MODEL_STORAGE_PROFILE=high-throughput-shared
export BENCHMARK_WORKLOAD_STORAGE_PROFILE=shared
export BENCHMARK_GPU_RELEASE_POLICY=after-load
export BENCHMARK_REPETITION=1
export BENCHMARK_CAMPAIGN_ID="optimized-baseline-qwen3-32b-h100-$(date -u +%Y%m%d-%H%M%S)"

export BENCHMARK_SECRET_NAMESPACE=benchmark-secrets
export BENCHMARK_HF_SECRET_NAME=llm-d-hf-token
test -n "${HF_TOKEN:?HF_TOKEN must be set}"

make benchmark-gke-plan
make benchmark-gke-provision

kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
  create namespace "${BENCHMARK_SECRET_NAMESPACE}" \
  --dry-run=client -o yaml |
kubectl --context "${BENCHMARK_KUBE_CONTEXT}" apply -f -

printf 'HF_TOKEN=%s\n' "${HF_TOKEN}" |
kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
  --namespace "${BENCHMARK_SECRET_NAMESPACE}" \
  create secret generic "${BENCHMARK_HF_SECRET_NAME}" \
  --from-env-file=/dev/stdin --dry-run=client -o yaml |
kubectl --context "${BENCHMARK_KUBE_CONTEXT}" apply -f -

finalize_campaign() {
  local campaign_status=$?
  local cleanup_status=0
  trap - EXIT
  make benchmark-gke-cleanup || cleanup_status=$?
  if (( campaign_status != 0 )); then
    exit "${campaign_status}"
  fi
  exit "${cleanup_status}"
}
trap finalize_campaign EXIT

for treatment in service agentgateway-standalone agentgateway-gateway; do
  # after-load returns this pool to zero while CPU-side collection and
  # reporting finish, so every subsequent treatment must reacquire it.
  make benchmark-gke-gpu-up
  BENCHMARK_TREATMENT="${treatment}" make benchmark
done

export BENCHMARK_CAMPAIGN_DIR="inference/results/llm-d-benchmark/${BENCHMARK_CAMPAIGN_ID}"
export BENCHMARK_COMPARISONS="service:agentgateway-standalone service:agentgateway-gateway"
export BENCHMARK_REPORT_FORMATS=markdown,png,csv
make benchmark-report
```

The native campaign evidence and generated reports are written to:

```text
inference/results/llm-d-benchmark/<campaign-id>/
inference/results/llm-d-benchmark/<campaign-id>/generated/
  service-vs-agentgateway-standalone/
  service-vs-agentgateway-gateway/
```

The finalizer deliberately runs after report generation. The `after-load`
policy has already released the GPU nodes, while keeping the campaign lock
until reporting finishes prevents another campaign from changing the shared
cluster during result validation.

For three repetitions, rotate treatment order to reduce cluster drift:

```text
round 1: service, agentgateway-standalone, agentgateway-gateway
round 2: agentgateway-gateway, service, agentgateway-standalone
round 3: agentgateway-standalone, agentgateway-gateway, service
```

Set `BENCHMARK_REPETITION` to the round number. Restarting model-server pods
between treatments clears runtime KV-cache state while the persistent model
weight cache can remain populated.

## Campaign duration and cost

Plan for approximately 6-7 hours and USD 400-425 for one complete GKE
campaign with the Service, standalone agentgateway, and agentgateway on
Kubernetes treatments at `BENCHMARK_REPETITION=1`. This estimate is based on
the `qwen3-32b-h100` model campaign in us-central1 with eight Spot `a3-highgpu-2g`
nodes, 16 H100 GPUs, and the `after-load` GPU release policy.

The measured campaign broke down as follows:

| Treatment | End-to-end time | GPU pool allocation |
|---|---:|---:|
| Kubernetes Service | About 2h05m | 82.5m |
| standalone agentgateway | About 2h10m | 92.4m |
| agentgateway on Kubernetes | About 1h40m | 60.0m |
| Final report generation | 5-10m | 0m |
| **Campaign total** | **About 6h-6h05m** | **About 3h55m** |

The GPU allocation intervals include node-pool provisioning and deletion
reconciliation. `after-load` releases the pool while inference-perf reporting,
result collection, compression, and teardown continue on CPU nodes. H100 Spot
capacity and model-download variability can increase the elapsed time. Allow
at least seven hours for the complete workflow.

An indicative per-campaign cost breakdown is:

| Resource | Estimated cost (USD) |
|---|---:|
| Eight Spot `a3-highgpu-2g` nodes | 380-400 |
| Temporary Premium and Standard Filestore | 7-10 |
| `e2-standard-32` and `e2-standard-4` CPU nodes for six hours | About 7.25 |
| GKE management | At most 0.60 |
| Result-transfer network egress | 5-7 |
| **Estimated total** | **400-425** |

The estimate uses the us-central1 Spot price observed on 2026-08-13 of
USD 12.652385205 per hour for each two-H100 `a3-highgpu-2g` node, or about
USD 101.22 per hour for the eight-node pool. Prices are variable and this is
not a billing quote. See the Google Cloud
[Spot VM](https://cloud.google.com/spot-vms/pricing),
[Filestore](https://cloud.google.com/filestore/pricing), and
[GKE](https://cloud.google.com/kubernetes-engine/pricing) pricing pages.

Each treatment temporarily needs about 17 GiB of local space while collecting
raw per-request results. The three compressed per-request files total
approximately 3 GiB, so copy long-lived evidence to durable object storage.
`BENCHMARK_REPETITION=3` runs every treatment three times and should be
budgeted at approximately 18 hours and USD 1,200 to 1,275.

## Results

New results use this campaign-oriented layout:

```text
inference/results/llm-d-benchmark/<campaign-id>/
  campaign-manifest.yaml
  .work/
  runs/
    service/
      repetition-1/
    agentgateway-standalone/
      repetition-1/
    agentgateway-gateway/
      repetition-1/
```

Each repetition contains standardized per-stage reports, native harness
configuration and summaries, rendered Kubernetes configuration, logs, and
runtime metrics when enabled. The upstream workload variant also retains
per-request results so percentiles can be independently audited.

## Generate Markdown and PNG reports

Generate the two Service comparisons after all treatments complete:

```bash
BENCHMARK_CAMPAIGN_DIR=inference/results/llm-d-benchmark/<campaign-id> \
BENCHMARK_COMPARISONS='service:agentgateway-standalone service:agentgateway-gateway' \
make benchmark-report
```

The reporting target creates a dedicated Python virtual environment under
`inference/.venv` and installs pinned, non-interactive reporting
dependencies. Direct invocation is also supported after installing
`reporting/requirements.txt`:

```bash
python inference/reporting/generate.py \
  --campaign inference/results/llm-d-benchmark/<campaign-id> \
  --comparison service:agentgateway-standalone \
  --comparison service:agentgateway-gateway \
  --formats markdown,png,csv
```

Each comparison produces:

```text
README.md
metrics.csv
throughput_vs_qps.png
latency_vs_qps.png
ttft_p90_vs_qps.png
```

The generator excludes a duplicate-rate warm-up stage, takes the median point
across repetitions, and refuses to compare treatments with different QPS
ladders or repetition counts. Its Markdown tables and three PNGs follow the
upstream optimized-baseline report layout: input/output/total throughput,
mean TTFT/ITL/NTPOT, and TTFT p90. Failure counts and rates remain available in
`metrics.csv` so latency can be interpreted correctly under overload.

Use `--output inference/reports/<suite>/<profile>/<campaign-id>`
to promote reviewed output into the curated reports tree. For example:

```bash
python inference/reporting/generate.py \
  --campaign inference/results/llm-d-benchmark/<campaign-id> \
  --comparison service:agentgateway-standalone \
  --comparison service:agentgateway-gateway \
  --formats markdown,png,csv \
  --output inference/reports/llm-d-benchmark/optimized-baseline-qwen3-32b-h100/<campaign-id>
```

Generated native-evidence links resolve locally because `results/` contains
the source campaign. Raw results are intentionally ignored by Git. Before
committing a curated report, replace those local links with durable archive
URLs or describe the external archive without creating broken repository
links.

## Configuration highlights

| Variable | Default |
|---|---|
| `BENCHMARK_SUITE` | `llm-d-benchmark` |
| `BENCHMARK_CLUSTER_PROVIDER` | `kind` |
| `BENCHMARK_ACCELERATOR_TYPE` / `BENCHMARK_BACKEND_TYPE` | `sim` / `inference-sim` |
| `BENCHMARK_ROUTER_MODE` | Derived from treatment |
| `BENCHMARK_HARNESS` | `inference-perf` (only supported value) |
| `BENCHMARK_WORKLOAD_VARIANT` | `upstream` |
| `BENCHMARK_RUNTIME_METRICS` | `true` |
| `BENCHMARK_GKE_MONITORING` | `auto` |
| `BENCHMARK_FAST_COLLECT` | `true` |
| `BENCHMARK_GPU_RELEASE_POLICY` | `never` |
| `BENCHMARK_GKE_GPU_NODEPOOL` | `gpu-h100` |
| `BENCHMARK_MODEL_CACHE_POLICY` | `ephemeral` |

Inference-perf is the only implemented harness. GuideLLM should be added only
with complete campaign defaults, report ingestion, GPU release behavior,
documentation, and end-to-end coverage; selecting it currently fails before
any benchmark resources are changed.

Provider-specific storage profiles use provider-prefixed low-level variables.
For example, the GKE high-throughput shared model profile resolves to
`premium-rwx`, while the shared harness profile resolves to `standard-rwx`.
GKE hardware inputs are provider-prefixed as well. The provisioning defaults
are `a3-highgpu-2g`, two `nvidia-h100-80gb` accelerators per node, and eight
target nodes; see [GKE benchmark provisioning](provisioning/gke/README.md) for
the complete contract.

List local and upstream scenarios with:

```bash
inference/run-benchmark.sh --list-scenarios
```

Remove only the managed llm-d-benchmark checkout and its virtual environment:

```bash
make benchmark-clean
```

This does not delete a Kubernetes cluster or a retained treatment.

## GKE campaign cleanup

The GKE cluster and node pools can be created independently with the
non-interactive `gcloud` provisioning layer:

```bash
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-plan
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-provision
BENCHMARK_GKE_PROJECT=<project> make benchmark-gke-gpu-up
```

The benchmark runner never provisions infrastructure implicitly. This keeps
cluster IAM and lifecycle failures separate from workload retries. The GPU
pool is created at zero nodes and scale-up rolls back to zero if its configured
readiness deadline expires.

GKE benchmark namespaces are labeled with their owning campaign. The wrapper
also acquires a cluster-wide campaign lock, so a different campaign cannot use
the same cluster until cleanup succeeds. With the default ephemeral cache
policy, treatment teardown explicitly deletes its PVCs and waits for their PVs
and Filestore instances to disappear.

Always run the campaign finalizer, including after interruption or failure. It
deletes remaining campaign-owned resources, verifies Filestore deletion,
scales the configured GPU node pool to zero, verifies its managed instance
groups and Kubernetes node count, and releases the campaign lock only after
every check passes:

```bash
make benchmark-gke-cleanup
```

The GPU node pool defaults to `gpu-h100`; all other GKE identity values are
required unless they can be derived from a standard
`gke_<project>_<location>_<cluster>` context name. A cleanup failure is
intentional: it prevents a subsequent campaign from hiding leaked resources.
