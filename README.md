# Benchmarks

Community benchmarks for agentgateway.

- [`inference/`](inference/README.md) — inference benchmark execution, results, and publishable reports (plain Kubernetes Service vs. agentgateway standalone vs. agentgateway on Kubernetes, run across GKE campaigns)

PR #1 intentionally migrates the inference benchmark tooling only. Published
benchmark reports and their supporting evidence will follow separately after
the tooling migration is complete.

Automated repository checks cover syntax and unit tests only; they do not
provision infrastructure or execute benchmark campaigns.
