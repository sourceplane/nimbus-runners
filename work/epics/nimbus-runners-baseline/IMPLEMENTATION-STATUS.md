# nimbus-runners-baseline (NR) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place the code departed from `design.md`.

| Milestone | State | PR |
|---|---|---|
| NR0 — the spec | ✅ merged, synced | [#1](https://github.com/sourceplane/nimbus-runners/pull/1), [#2](https://github.com/sourceplane/nimbus-runners/pull/2) |
| NR1 — foundations | ✅ | NR-2; [stack-granite#1](https://github.com/sourceplane/stack-granite/pull/1) + tag v0.1.0; [aws-admin#35](https://github.com/sourceplane/aws-admin/pull/35) |
| NR2 — the fleet | ✅ applied to prod; App `sourceplane-nimbus-runners` installed | NR-3: [#4](https://github.com/sourceplane/nimbus-runners/pull/4), [#5](https://github.com/sourceplane/nimbus-runners/pull/5), [#6](https://github.com/sourceplane/nimbus-runners/pull/6) |
| NR3 — the image | image live; burst test waits on the Lambda quota | NR-4: [#7](https://github.com/sourceplane/nimbus-runners/pull/7), [#8](https://github.com/sourceplane/nimbus-runners/pull/8), [#10](https://github.com/sourceplane/nimbus-runners/pull/10) |
| NR4 — orun-cloud on the fleet | | |
| NR5 — the baseline | | |

## Measurements

| Measure | Target | Measured |
|---|---|---|
| p50 launch-to-job-start | < 60 s | ≈ 55–60 s. Queue-to-start is 87 s p50 over 15 lanes (2026-09-30), which includes the 10 s webhook delay, the queued check and CreateFleet |
| 100-job burst, worst wait for a runner | < 3 min | not yet run. A 20-lane test lost 9 of 20 webhook deliveries to Lambda throttling (see below) |
| Spot vCPU quota `L-34B43A08` | ≥ 200 | increase requested 2026-09-30 |
| Lambda concurrency `L-B99A9384` | 1,000 | 10 (fresh account); increase requested 2026-09-30 |
| orun-cloud monthly run-rate on the fleet | ≤ $55 at the 30-day volume | |

## Departures from the design

### One role, not a plan/deploy pair (NR1)

The design named a plan role for pull requests and main, and a deploy role for `prod`. stack-granite's `terraform-aws` takes one `awsRoleArn` per environment, and orun has no per-trigger parameter override. So the PR plan lane and the main apply lane assume one role, `github-sourceplane-nimbus-runners`, trusted for `pull_request` and `ref:refs/heads/main`.

What limits it:
- Fork pull requests never receive an OIDC token.
- Every role the fleet creates must carry `nimbus-runners-boundary`, which the role cannot loosen.
- IAM, Lambda, SQS, SSM, S3, logs, events and budgets are scoped to `nimbus-runners*`.

### One Terraform root, not three components (NR2)

The design split the fleet into `infra/network`, `infra/runners` and `infra/budget`, wired through `secretOutputs` → `secretEnv`. That wiring makes a pull request's plan of `runners` depend on a secret that only a previous apply of `network` publishes. The first PR could never plan clean. The fleet ships as one root, `infra/fleet`, with the same files (`network.tf`, `lambdas.tf`, `runners.tf`, `budget.tf`). Splitting it later is a state move, not a redesign.

### Findings from the first smoke tests (NR3, 2026-09-30)

- **The image lost its start script.** `cloud-init clean` wipes `/var/lib/cloud`, including `scripts/per-boot/start-runner.sh`. The first image booted, never registered, and scale-down reaped it. Fixed in #10: clear only the instance state, and fail the build if the script is missing.
- **What a lane sees on the image.** Spot lifecycle, user `runner` at `/home/runner`, Docker 29.8, node 20.20.2 and 22.23.3 in the hosted tool cache (`setup-node` resolves from cache), AWS CLI 2, 2 vCPU / 8 GiB, 38 GB root volume.
- **Bursts need the Lambda quota.** With the account limit at 10 concurrent executions, 20 simultaneous `workflow_job` deliveries throttled the webhook lambda. Only 11 of 20 `queued` deliveries were accepted, and GitHub does not redeliver a failed webhook. Bursts are reliable only once `L-B99A9384` is raised.
