# nimbus-runners-baseline (NR) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place the code departed from `design.md`.

| Milestone | State | PR |
|---|---|---|
| NR0 — the spec | ✅ merged, synced | [#1](https://github.com/sourceplane/nimbus-runners/pull/1), [#2](https://github.com/sourceplane/nimbus-runners/pull/2) |
| NR1 — foundations | ✅ | NR-2; [stack-granite#1](https://github.com/sourceplane/stack-granite/pull/1) + tag v0.1.0; [aws-admin#35](https://github.com/sourceplane/aws-admin/pull/35) |
| NR2 — the fleet | applied to prod; GitHub App pending | NR-3: [#4](https://github.com/sourceplane/nimbus-runners/pull/4), [#5](https://github.com/sourceplane/nimbus-runners/pull/5), [#6](https://github.com/sourceplane/nimbus-runners/pull/6) |
| NR3 — the image | in progress | NR-4 |
| NR4 — orun-cloud on the fleet | | |
| NR5 — the baseline | | |

## Measurements

| Measure | Target | Measured |
|---|---|---|
| p50 launch-to-job-start | < 60 s | |
| 100-job burst, worst wait for a runner | < 3 min | |
| Spot vCPU quota `L-34B43A08` | ≥ 200 | |
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
