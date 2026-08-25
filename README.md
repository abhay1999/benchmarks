# Benchmarks

Community benchmarks for Agentgateway.

- [`inference/`](inference/README.md) — inference benchmark execution, results, and publishable reports (plain Kubernetes Service vs. Agentgateway standalone vs. Agentgateway on Kubernetes, run across GKE campaigns)
- [`regression/`](regression/README.md) — automated regression detection: compares a benchmark run's tail latency against a stored baseline and fails CI if it degrades past a threshold
