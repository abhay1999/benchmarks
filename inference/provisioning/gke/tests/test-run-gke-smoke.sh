#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_SCRIPT="$(cd "${SCRIPT_DIR}/../../.." && pwd)/run-gke-smoke.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT
mkdir -p "${TEMP_DIR}/bin"

cat >"${TEMP_DIR}/bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -C ]]
[[ "$2" == "${TEST_REPO_ROOT}" ]]
target="${!#}"
printf 'make target=%s campaign=%s accelerator=%s reference=%s model_storage=%s workload_storage=%s\n' \
  "${target}" "${BENCHMARK_CAMPAIGN_ID:-}" \
  "${BENCHMARK_ACCELERATOR_TYPE:-}" \
  "${BENCHMARK_REFERENCE_PROFILE:-}" \
  "${BENCHMARK_MODEL_STORAGE_PROFILE:-}" \
  "${BENCHMARK_WORKLOAD_STORAGE_PROFILE:-}" >>"${TEST_COMMAND_LOG}"
if [[ "${target}" == "${TEST_FAIL_TARGET:-none}" ]]; then
  exit 41
fi
EOF

cat >"${TEMP_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"${TEST_COMMAND_LOG}"
args=" $* "
if [[ "${args}" == *" create namespace "* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: benchmark-secrets\n'
elif [[ "${args}" == *" apply -f - "* ]]; then
  while IFS= read -r _; do :; done
elif [[ "${args}" == *" get secret "* && "${args}" == *" --template="* ]]; then
  [[ "${TEST_SECRET_EXISTS:-true}" == true ]] || exit 1
  printf 'hf_test'
elif [[ "${args}" == *" get secret "* ]]; then
  [[ "${TEST_SECRET_EXISTS:-true}" == true ]]
fi
EOF

cat >"${TEMP_DIR}/bin/verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
accelerator=""
while (( $# > 0 )); do
  if [[ "$1" == --accelerator ]]; then
    accelerator="$2"
    shift 2
  else
    shift
  fi
done
printf 'verify accelerator=%s\n' "${accelerator}" >>"${TEST_COMMAND_LOG}"
[[ "${accelerator}" != "${TEST_VERIFY_FAIL_ACCELERATOR:-none}" ]]
EOF

chmod +x "${TEMP_DIR}/bin/make" "${TEMP_DIR}/bin/kubectl" \
  "${TEMP_DIR}/bin/verify"
export PATH="${TEMP_DIR}/bin:/usr/bin:/bin"
export BENCHMARK_MAKE_BIN="${TEMP_DIR}/bin/make"
export BENCHMARK_SMOKE_VERIFY_BIN="${TEMP_DIR}/bin/verify"
export BENCHMARK_GKE_PROJECT=test-project
export BENCHMARK_GKE_NODE_SERVICE_ACCOUNT=default
export BENCHMARK_SMOKE_ID=test-smoke
export TEST_REPO_ROOT="${REPO_ROOT}"
export TEST_COMMAND_LOG="${TEMP_DIR}/commands.log"

: >"${TEST_COMMAND_LOG}"
"${SMOKE_SCRIPT}" all >"${TEMP_DIR}/success.log"
[[ "$(grep -c '^make target=benchmark ' "${TEST_COMMAND_LOG}")" == 2 ]]
[[ "$(grep -c '^make target=benchmark-gke-gpu-up ' "${TEST_COMMAND_LOG}")" == 1 ]]
[[ "$(grep -c '^make target=benchmark-gke-cleanup ' "${TEST_COMMAND_LOG}")" == 2 ]]
grep -q '^verify accelerator=sim$' "${TEST_COMMAND_LOG}"
grep -q '^verify accelerator=gpu$' "${TEST_COMMAND_LOG}"
sim_verify_line="$(grep -n '^verify accelerator=sim$' "${TEST_COMMAND_LOG}" | cut -d: -f1)"
gpu_up_line="$(grep -n '^make target=benchmark-gke-gpu-up ' "${TEST_COMMAND_LOG}" | cut -d: -f1)"
(( sim_verify_line < gpu_up_line ))
grep -q '^make target=benchmark .* accelerator=gpu reference=smoke-gpu model_storage=default workload_storage=default$' \
  "${TEST_COMMAND_LOG}"

: >"${TEST_COMMAND_LOG}"
set +e
TEST_VERIFY_FAIL_ACCELERATOR=sim "${SMOKE_SCRIPT}" all \
  >"${TEMP_DIR}/failure.log" 2>&1
status=$?
set -e
[[ "${status}" == 1 ]]
grep -q '^verify accelerator=sim$' "${TEST_COMMAND_LOG}"
if grep -q '^make target=benchmark-gke-gpu-up ' "${TEST_COMMAND_LOG}"; then
  echo "GPU capacity was acquired after simulator verification failed" >&2
  exit 1
fi
grep -q '^make target=benchmark-gke-cleanup ' "${TEST_COMMAND_LOG}"

: >"${TEST_COMMAND_LOG}"
BENCHMARK_GKE_CLUSTER_LIFECYCLE=destroy "${SMOKE_SCRIPT}" sim \
  >"${TEMP_DIR}/destroy.log"
[[ "$(tail -n 1 "${TEST_COMMAND_LOG}")" == make\ target=benchmark-gke-destroy* ]]

if BENCHMARK_SMOKE_GPU_TARGET_NODES=2 "${SMOKE_SCRIPT}" gpu \
  >"${TEMP_DIR}/unsafe.log" 2>&1; then
  echo "unsafe smoke GPU target was unexpectedly accepted" >&2
  exit 1
fi
grep -q 'BENCHMARK_SMOKE_GPU_TARGET_NODES must be 1' "${TEMP_DIR}/unsafe.log"

: >"${TEST_COMMAND_LOG}"
TEST_SECRET_EXISTS=false "${SMOKE_SCRIPT}" sim >"${TEMP_DIR}/public-model.log"
grep -q 'public smoke model will use unauthenticated access' \
  "${TEMP_DIR}/public-model.log"

echo "GKE smoke orchestration tests passed"
