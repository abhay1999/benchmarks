# Gap 3 - regression detection (scoping, not pushed yet)

Committed on the local `gsoc/gap3-regression` branch, but not pushed anywhere
- still figuring out where baselines should live long-term (Azure Blob per
the original proposal, or just checked into the repo for now given the
timeline).

- `check_regression.py` - compares a benchmark report's p99 request latency
  against a stored `baseline.json`, exits non-zero past the threshold.
  Tested against real reports from the Gap 2 runs, works.
- `update_baseline.py` - writes a `baseline.json` from a report. Meant to be
  run by hand after a release is reviewed, not automatic.
- `baselines/` - generated locally from the 2026-08-04 Gap 2 runs (both
  arms, `sanity_random` workload) - for testing the script, not reviewed
  numbers yet.
- `benchmark-regression.yml` - draft GitHub Actions workflow, not moved into
  `.github/workflows/` yet. Runs both arms via `run-benchmark.sh`, then
  checks each arm's report against its baseline.

## Still missing before this is real

- The `baselines/*.json` here are from a local test run, not reviewed/
  official numbers - fine for testing the mechanism, not what should
  actually gate a release yet
- Haven't run the workflow itself in CI (can't, it's not in
  `.github/workflows/` yet)
- No decision from Daneyon/Nina on Azure Blob vs in-repo storage
- Not pushed anywhere - waiting on Daneyon's confirmation before pushing at
  all, per instruction
