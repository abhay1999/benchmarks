#!/usr/bin/env bash
# Run a gated, minimal GKE smoke campaign. The simulator phase never allocates
# GPUs; the GPU phase uses one Spot node and releases it after traffic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAKE_BIN="${BENCHMARK_MAKE_BIN:-make}"
WORKLOAD_FILE="${SCRIPT_DIR}/suites/llm-d-benchmark/workloads/smoke.yaml"
VERIFY_SCRIPT="${SCRIPT_DIR}/suites/llm-d-benchmark/scripts/verify_smoke_results.py"
ACTIVE_CAMPAIGN=""
FINALIZER_ARMED=false

log() { echo "[gke-smoke] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

run_make() {
  "${MAKE_BIN}" -C "${REPO_ROOT}" "$@"
}

set_defaults() {
  : "${BENCHMARK_GKE_PROJECT:?BENCHMARK_GKE_PROJECT is required}"
  : "${BENCHMARK_GKE_LOCATION:=us-central1-a}"
  : "${BENCHMARK_GKE_CLUSTER:=agentgateway-benchmark}"
  : "${BENCHMARK_KUBE_CONTEXT:=gke_${BENCHMARK_GKE_PROJECT}_${BENCHMARK_GKE_LOCATION}_${BENCHMARK_GKE_CLUSTER}}"
  : "${BENCHMARK_GKE_CPU_NODEPOOL:=default-pool}"
  : "${BENCHMARK_GKE_HARNESS_NODEPOOL:=bench-cpu}"
  : "${BENCHMARK_GKE_GPU_NODEPOOL:=gpu-h100}"
  : "${BENCHMARK_GKE_GPU_MACHINE_TYPE:=a3-highgpu-2g}"
  : "${BENCHMARK_GKE_GPU_ACCELERATOR_TYPE:=nvidia-h100-80gb}"
  : "${BENCHMARK_GKE_GPU_ACCELERATORS_PER_NODE:=2}"
  : "${BENCHMARK_GKE_CLUSTER_LIFECYCLE:=retain}"
  : "${BENCHMARK_SMOKE_TREATMENT:=agentgateway-gateway}"
  : "${BENCHMARK_SMOKE_AGW_VERSION:=v1.4.1}"
  : "${BENCHMARK_SMOKE_GPU_TARGET_NODES:=1}"
  : "${BENCHMARK_SMOKE_ID:=gke-smoke-$(date -u +%Y%m%d-%H%M%S)}"
  : "${BENCHMARK_SECRET_NAMESPACE:=benchmark-secrets}"
  : "${BENCHMARK_HF_SECRET_NAME:=llm-d-hf-token}"

  case "${BENCHMARK_GKE_CLUSTER_LIFECYCLE}" in
    retain|destroy) ;;
    *) die "BENCHMARK_GKE_CLUSTER_LIFECYCLE must be retain or destroy" ;;
  esac
  case "${BENCHMARK_SMOKE_TREATMENT}" in
    service|agentgateway-standalone|agentgateway-gateway|envoy-standalone) ;;
    *) die "unsupported BENCHMARK_SMOKE_TREATMENT=${BENCHMARK_SMOKE_TREATMENT}" ;;
  esac
  [[ "${BENCHMARK_SMOKE_GPU_TARGET_NODES}" == 1 ]] || \
    die "BENCHMARK_SMOKE_GPU_TARGET_NODES must be 1"
  [[ "${BENCHMARK_SMOKE_ID}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || \
    die "BENCHMARK_SMOKE_ID must contain lowercase letters, digits, dots, or hyphens"
  [[ -f "${WORKLOAD_FILE}" ]] || die "missing smoke workload ${WORKLOAD_FILE}"
  [[ -f "${VERIFY_SCRIPT}" ]] || die "missing smoke verifier ${VERIFY_SCRIPT}"

  # Override ambient full-campaign values. A smoke target must not silently
  # inherit eight replicas, the upstream saturation workload, or on-demand GPUs.
  export BENCHMARK_GKE_GPU_TARGET_NODES=1
  export BENCHMARK_GKE_GPU_SPOT=true
  export BENCHMARK_GKE_PROJECT BENCHMARK_GKE_LOCATION BENCHMARK_GKE_CLUSTER
  export BENCHMARK_KUBE_CONTEXT BENCHMARK_GKE_CPU_NODEPOOL
  export BENCHMARK_GKE_HARNESS_NODEPOOL BENCHMARK_GKE_GPU_NODEPOOL
  export BENCHMARK_GKE_GPU_MACHINE_TYPE BENCHMARK_GKE_GPU_ACCELERATOR_TYPE
  export BENCHMARK_GKE_GPU_ACCELERATORS_PER_NODE BENCHMARK_GKE_GPU_TARGET_NODES
  export BENCHMARK_GKE_GPU_SPOT BENCHMARK_GKE_CLUSTER_LIFECYCLE
  export BENCHMARK_SECRET_NAMESPACE BENCHMARK_HF_SECRET_NAME
}

ensure_hf_secret() {
  kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
    create namespace "${BENCHMARK_SECRET_NAMESPACE}" \
    --dry-run=client -o yaml |
    kubectl --context "${BENCHMARK_KUBE_CONTEXT}" apply -f - >/dev/null

  if kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
      --namespace "${BENCHMARK_SECRET_NAMESPACE}" \
      get secret "${BENCHMARK_HF_SECRET_NAME}" >/dev/null 2>&1; then
    local token
    token="$(kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
      --namespace "${BENCHMARK_SECRET_NAMESPACE}" \
      get secret "${BENCHMARK_HF_SECRET_NAME}" \
      --template='{{index .data "HF_TOKEN" | base64decode}}')"
    [[ "${token}" == hf_* ]] || \
      die "${BENCHMARK_SECRET_NAMESPACE}/${BENCHMARK_HF_SECRET_NAME} has no valid HF_TOKEN key"
    unset token
    log "using existing ${BENCHMARK_SECRET_NAMESPACE}/${BENCHMARK_HF_SECRET_NAME}"
    return
  fi

  if [[ -z "${HF_TOKEN:-}" ]]; then
    log "no HF token found; the public smoke model will use unauthenticated access"
    return
  fi
  [[ "${HF_TOKEN}" == hf_* ]] || die "HF_TOKEN must start with hf_"
  printf 'HF_TOKEN=%s\n' "${HF_TOKEN}" |
    kubectl --context "${BENCHMARK_KUBE_CONTEXT}" \
      --namespace "${BENCHMARK_SECRET_NAMESPACE}" \
      create secret generic "${BENCHMARK_HF_SECRET_NAME}" \
      --from-env-file=/dev/stdin --dry-run=client -o yaml |
    kubectl --context "${BENCHMARK_KUBE_CONTEXT}" apply -f - >/dev/null
  log "created ${BENCHMARK_SECRET_NAMESPACE}/${BENCHMARK_HF_SECRET_NAME}"
}

benchmark_python() {
  if [[ -n "${BENCHMARK_SMOKE_VERIFY_BIN:-}" ]]; then
    printf '%s\n' "${BENCHMARK_SMOKE_VERIFY_BIN}"
    return
  fi
  local checkout
  checkout="${LLM_D_BENCHMARK_DIR:-${LLM_D_BENCHMARK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/agentgateway-benchmark/llm-d-benchmark}}"
  [[ -x "${checkout}/.venv/bin/python" ]] || \
    die "llm-d-benchmark Python is missing after the run: ${checkout}/.venv/bin/python"
  printf '%s\n' "${checkout}/.venv/bin/python"
}

verify_results() {
  local accelerator="$1" campaign_dir python
  campaign_dir="${BENCHMARK_RESULTS_DIR:-${SCRIPT_DIR}/results/llm-d-benchmark}/${ACTIVE_CAMPAIGN}"
  python="$(benchmark_python)"
  "${python}" "${VERIFY_SCRIPT}" --campaign "${campaign_dir}" \
    --treatment "${BENCHMARK_SMOKE_TREATMENT}" --accelerator "${accelerator}"
}

cleanup_active_campaign() {
  [[ -n "${ACTIVE_CAMPAIGN}" ]] || return 0
  export BENCHMARK_CAMPAIGN_ID="${ACTIVE_CAMPAIGN}"
  log "cleaning campaign ${ACTIVE_CAMPAIGN} and returning the GPU pool to zero"
  run_make benchmark-gke-cleanup
  ACTIVE_CAMPAIGN=""
  unset BENCHMARK_CAMPAIGN_ID
}

finalize() {
  local campaign_status=$? cleanup_status=0 destroy_status=0
  trap - EXIT INT TERM
  if [[ "${FINALIZER_ARMED}" == true ]]; then
    cleanup_active_campaign || cleanup_status=$?
    if [[ "${BENCHMARK_GKE_CLUSTER_LIFECYCLE}" == destroy ]]; then
      if (( cleanup_status == 0 )); then
        export BENCHMARK_GKE_DESTROY_IF_MISSING=true
        run_make benchmark-gke-destroy || destroy_status=$?
        unset BENCHMARK_GKE_DESTROY_IF_MISSING
      else
        log "ERROR: refusing cluster deletion because campaign cleanup failed" >&2
      fi
    fi
  fi
  if (( campaign_status != 0 )); then
    exit "${campaign_status}"
  fi
  if (( cleanup_status != 0 )); then
    exit "${cleanup_status}"
  fi
  exit "${destroy_status}"
}

configure_phase() {
  local accelerator="$1"
  export BENCHMARK_CLUSTER_PROVIDER=gke
  export BENCHMARK_SUITE=llm-d-benchmark
  export BENCHMARK_TREATMENT="${BENCHMARK_SMOKE_TREATMENT}"
  export BENCHMARK_CAMPAIGN_ID="${ACTIVE_CAMPAIGN}"
  export BENCHMARK_REPETITION=1
  export BENCHMARK_SCENARIO=agentgateway-comparison
  export BENCHMARK_ROUTING_POLICY=default
  export BENCHMARK_REFERENCE_PROFILE=
  export BENCHMARK_WORKLOAD_FILE_PATH="${WORKLOAD_FILE}"
  export BENCHMARK_WORKLOAD_VARIANT=upstream
  export BENCHMARK_ENDPOINT_PATH=internal
  export BENCHMARK_RUNTIME_METRICS=true
  export BENCHMARK_FAST_COLLECT=true
  export BENCHMARK_HF_TOKEN_REQUIRED=false
  export BENCHMARK_MODEL_CACHE_POLICY=ephemeral
  export BENCHMARK_RESUME=false
  export AGW_VERSION="${BENCHMARK_SMOKE_AGW_VERSION}"
  export BENCHMARK_MODEL=facebook/opt-125m
  export BENCHMARK_REPLICAS=1
  export BENCHMARK_MODEL_STORAGE_STRATEGY=default
  export BENCHMARK_MODEL_STORAGE_CLASS=
  export BENCHMARK_MODEL_STORAGE_SIZE=
  export BENCHMARK_WORKLOAD_STORAGE_CLASS=
  export BENCHMARK_WORKLOAD_STORAGE_SIZE=

  if [[ "${accelerator}" == sim ]]; then
    export BENCHMARK_ACCELERATOR_TYPE=sim
    export BENCHMARK_ACCELERATOR_MODEL=auto
    export BENCHMARK_BACKEND_TYPE=inference-sim
    export BENCHMARK_TENSOR_PARALLELISM=0
    export BENCHMARK_MODEL_STORAGE_PROFILE=default
    export BENCHMARK_WORKLOAD_STORAGE_PROFILE=default
    export BENCHMARK_GPU_RELEASE_POLICY=never
  else
    export BENCHMARK_ACCELERATOR_TYPE=gpu
    export BENCHMARK_ACCELERATOR_MODEL=h100
    export BENCHMARK_BACKEND_TYPE=vllm
    export BENCHMARK_TENSOR_PARALLELISM=1
    export BENCHMARK_REFERENCE_PROFILE=smoke-gpu
    export BENCHMARK_MODEL_STORAGE_PROFILE=default
    export BENCHMARK_WORKLOAD_STORAGE_PROFILE=default
    export BENCHMARK_GPU_RELEASE_POLICY=after-load
  fi
}

run_phase() {
  local accelerator="$1"
  ACTIVE_CAMPAIGN="${BENCHMARK_SMOKE_ID}-${accelerator}"
  configure_phase "${accelerator}"
  if [[ "${accelerator}" == gpu ]]; then
    log "acquiring one Spot GPU node"
    run_make benchmark-gke-gpu-up
  fi
  log "running ${accelerator} smoke campaign ${ACTIVE_CAMPAIGN}"
  run_make benchmark
  verify_results "${accelerator}"
  cleanup_active_campaign
}

main() {
  [[ $# -eq 1 ]] || die "usage: run-gke-smoke.sh sim|gpu|all"
  local mode="$1"
  case "${mode}" in sim|gpu|all) ;; *) die "usage: run-gke-smoke.sh sim|gpu|all" ;; esac
  command -v "${MAKE_BIN}" >/dev/null 2>&1 || die "${MAKE_BIN} is required"
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
  set_defaults

  log "smoke ID: ${BENCHMARK_SMOKE_ID}"
  log "cluster lifecycle: ${BENCHMARK_GKE_CLUSTER_LIFECYCLE}"
  run_make benchmark-gke-plan
  if [[ "${BENCHMARK_GKE_CLUSTER_LIFECYCLE}" == destroy ]]; then
    FINALIZER_ARMED=true
    trap finalize EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  run_make benchmark-gke-provision
  if [[ "${FINALIZER_ARMED}" != true ]]; then
    FINALIZER_ARMED=true
    trap finalize EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  run_make KUBE_CONTEXT="${BENCHMARK_KUBE_CONTEXT}" gw-api-crds gie-crds
  ensure_hf_secret

  if [[ "${mode}" == sim || "${mode}" == all ]]; then
    run_phase sim
  fi
  if [[ "${mode}" == gpu || "${mode}" == all ]]; then
    run_phase gpu
  fi
  log "smoke campaign completed successfully"
}

main "$@"
