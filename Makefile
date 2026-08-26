#----------------------------------------------------------------------------------
# MARK: Benchmarking
#----------------------------------------------------------------------------------

CLUSTER_NAME ?= agentgateway-benchmark

# The version of the Node Docker image to use for booting the kind cluster: https://hub.docker.com/r/kindest/node/tags
CLUSTER_NODE_VERSION ?= v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5

.PHONY: kind-create
kind-create: ## Create a KinD cluster
	kind get clusters | grep $(CLUSTER_NAME) || kind create cluster --name $(CLUSTER_NAME) --image kindest/node:$(CLUSTER_NODE_VERSION)

# Pinned to match the version agentgateway/agentgateway is built against.
# Update alongside that repo's sigs.k8s.io/gateway-api version.
CONFORMANCE_CHANNEL ?= experimental
CONFORMANCE_VERSION ?= v1.6.1
.PHONY: gw-api-crds
gw-api-crds: ## Install the Gateway API CRDs
	kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$(CONFORMANCE_VERSION)/$(CONFORMANCE_CHANNEL)-install.yaml"

# Pinned to match the version agentgateway/agentgateway is built against.
# Update alongside that repo's sigs.k8s.io/gateway-api-inference-extension version.
GIE_CRD_VERSION ?= v1.5.0
.PHONY: gie-crds
gie-crds: ## Install the Gateway API Inference Extension CRDs
	kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GIE_CRD_VERSION)/manifests.yaml"

# Set to the same cluster used by kind-create so we don't spin up a second one.
BENCHMARK_LLM_D_BENCHMARK_DIR ?=
BENCHMARK_CLUSTER_PROVIDER ?= kind
BENCHMARK_SUITE ?= llm-d-benchmark
BENCHMARK_REPETITION ?= 1

.PHONY: benchmark
benchmark: CLUSTER_NAME = agentgateway-benchmark
benchmark: ## Run one inference benchmark treatment in a shared campaign
	@case "$(BENCHMARK_CLUSTER_PROVIDER)" in kind|gke) ;; *) echo "unsupported BENCHMARK_CLUSTER_PROVIDER=$(BENCHMARK_CLUSTER_PROVIDER)" >&2; exit 2;; esac
	@test -n "$(BENCHMARK_TREATMENT)" || { echo "BENCHMARK_TREATMENT is required" >&2; exit 2; }
	@test -n "$(BENCHMARK_CAMPAIGN_ID)" || { echo "BENCHMARK_CAMPAIGN_ID is required" >&2; exit 2; }
	@if [ "$(BENCHMARK_CLUSTER_PROVIDER)" = kind ]; then $(MAKE) kind-create CLUSTER_NAME="$(CLUSTER_NAME)"; fi
	CLUSTER_NAME=$(CLUSTER_NAME) \
	  BENCHMARK_SUITE=$(BENCHMARK_SUITE) \
	  BENCHMARK_TREATMENT=$(BENCHMARK_TREATMENT) \
	  BENCHMARK_CAMPAIGN_ID=$(BENCHMARK_CAMPAIGN_ID) \
	  BENCHMARK_REPETITION=$(BENCHMARK_REPETITION) \
	  BENCHMARK_CLUSTER_PROVIDER=$(BENCHMARK_CLUSTER_PROVIDER) \
	  LLM_D_BENCHMARK_DIR=$(BENCHMARK_LLM_D_BENCHMARK_DIR) \
	  inference/run-benchmark.sh

.PHONY: benchmark-clean
benchmark-clean: ## Remove the llm-d-benchmark clone/CLI managed by `make benchmark` (leaves the kind cluster alone)
	LLM_D_BENCHMARK_DIR=$(BENCHMARK_LLM_D_BENCHMARK_DIR) inference/run-benchmark.sh --clean

.PHONY: benchmark-gke-cleanup
benchmark-gke-cleanup: ## Delete one GKE campaign's resources and scale its GPU pool to zero
	inference/cleanup-gke-campaign.sh

.PHONY: benchmark-gke-all
benchmark-gke-all: ## Run the complete three-treatment optimized-baseline GKE campaign
	inference/run-gke-campaign.sh

.PHONY: benchmark-gke-plan
benchmark-gke-plan: ## Validate prerequisites and show the desired GKE infrastructure
	inference/provisioning/gke/provision.sh plan

.PHONY: benchmark-gke-provision
benchmark-gke-provision: ## Create or verify the GKE benchmark infrastructure
	inference/provisioning/gke/provision.sh apply

.PHONY: benchmark-gke-verify
benchmark-gke-verify: ## Verify the existing GKE benchmark infrastructure
	inference/provisioning/gke/verify.sh

.PHONY: benchmark-gke-gpu-up
benchmark-gke-gpu-up: ## Scale the GKE GPU pool to its configured target
	inference/provisioning/gke/scale-gpu.sh up

.PHONY: benchmark-gke-gpu-down
benchmark-gke-gpu-down: ## Scale the GKE GPU pool to zero
	inference/provisioning/gke/scale-gpu.sh down

.PHONY: benchmark-gke-destroy
benchmark-gke-destroy: ## Delete idle provisioner-owned GKE infrastructure
	BENCHMARK_GKE_ALLOW_DESTROY=true inference/provisioning/gke/destroy.sh

BENCHMARK_REPORT_VENV := inference/.venv
BENCHMARK_REPORT_REQUIREMENTS := inference/reporting/requirements.txt
BENCHMARK_REPORT_STAMP := $(BENCHMARK_REPORT_VENV)/.requirements.stamp
BENCHMARK_REPORT_FORMATS ?= markdown,png,csv

$(BENCHMARK_REPORT_STAMP): $(BENCHMARK_REPORT_REQUIREMENTS)
	@test -x $(BENCHMARK_REPORT_VENV)/bin/python || python3 -m venv $(BENCHMARK_REPORT_VENV)
	PIP_DISABLE_PIP_VERSION_CHECK=1 $(BENCHMARK_REPORT_VENV)/bin/python -m pip install --no-input -r $(BENCHMARK_REPORT_REQUIREMENTS)
	@touch $(BENCHMARK_REPORT_STAMP)

.PHONY: benchmark-report
benchmark-report: $(BENCHMARK_REPORT_STAMP) ## Generate reports (BENCHMARK_CAMPAIGN_DIR and BENCHMARK_COMPARISONS required)
	@test -n "$(BENCHMARK_CAMPAIGN_DIR)" || { echo "BENCHMARK_CAMPAIGN_DIR is required" >&2; exit 2; }
	@test -n "$(BENCHMARK_COMPARISONS)" || { echo "BENCHMARK_COMPARISONS is required" >&2; exit 2; }
	@set --; for comparison in $(BENCHMARK_COMPARISONS); do set -- "$$@" --comparison "$$comparison"; done; \
	  $(BENCHMARK_REPORT_VENV)/bin/python inference/reporting/generate.py \
	    --campaign "$(BENCHMARK_CAMPAIGN_DIR)" --formats "$(BENCHMARK_REPORT_FORMATS)" "$$@"
