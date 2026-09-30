# nimbus-runners-baseline (NR) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place the code departed from `design.md`.

| Milestone | State | PR |
|---|---|---|
| NR0 — the spec | ✅ merged, synced | [#1](https://github.com/sourceplane/nimbus-runners/pull/1), [#2](https://github.com/sourceplane/nimbus-runners/pull/2) |
| NR1 — foundations | ✅ | NR-2; [stack-granite#1](https://github.com/sourceplane/stack-granite/pull/1) + tag v0.1.0; [aws-admin#35](https://github.com/sourceplane/aws-admin/pull/35) |
| NR2 — the fleet | ✅ applied to prod; App `sourceplane-nimbus-runners` installed | NR-3: [#4](https://github.com/sourceplane/nimbus-runners/pull/4), [#5](https://github.com/sourceplane/nimbus-runners/pull/5), [#6](https://github.com/sourceplane/nimbus-runners/pull/6) |
| NR3 — the image | image live; burst test waits on the Lambda quota | NR-4: [#7](https://github.com/sourceplane/nimbus-runners/pull/7), [#8](https://github.com/sourceplane/nimbus-runners/pull/8), [#10](https://github.com/sourceplane/nimbus-runners/pull/10), [#13](https://github.com/sourceplane/nimbus-runners/pull/13), [#14](https://github.com/sourceplane/nimbus-runners/pull/14), [#15](https://github.com/sourceplane/nimbus-runners/pull/15), [#16](https://github.com/sourceplane/nimbus-runners/pull/16) |
| NR4 — orun-cloud on the fleet | **cut over 2026-09-30**; 7-day watch running | NR-5: [orun-cloud#1732](https://github.com/sourceplane/orun-cloud/pull/1732) (merged), trial [#1730](https://github.com/sourceplane/orun-cloud/pull/1730) (closed) |
| NR5 — the baseline | | |

## Measurements

| Measure | Target | Measured |
|---|---|---|
| p50 launch-to-job-start | < 60 s | ≈ 55–60 s. Queue-to-start is 87 s p50 over 15 lanes (2026-09-30), which includes the 10 s webhook delay, the queued check and CreateFleet |
| 100-job burst, worst wait for a runner | < 3 min | 50-job burst: 50/50 passed. orun-cloud cold 51-lane run: 51/51 passed, 47 started within 90 s of `plan` (p50 74 s), worst 245 s |
| Spot vCPU quota `L-34B43A08` | ≥ 200 | 200 ✅ |
| Lambda concurrency `L-B99A9384` | 1,000 | 10; increase to 1,500 pending. The redelivery sweeper (#19, #21, #23) covers bursts until then |
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

### The orun-cloud trial (NR4, 2026-09-30)

[sourceplane/orun-cloud#1730](https://github.com/sourceplane/orun-cloud/pull/1730) ran one 17-lane selection (sdk + policy-engine) twice: on the fleet ([run A4](https://github.com/sourceplane/orun-cloud/actions/runs/36697087914)) and on GitHub-hosted runners ([run B](https://github.com/sourceplane/orun-cloud/actions/runs/36689537980)).

| | nimbus | hosted |
|---|---|---|
| Lanes passed | 17/17 | 17/17 |
| Per-lane run, p50 | 91 s | 128 s |
| Per-lane run vs hosted, median | 0.71× | 1× |
| Runner time, summed | 28.2 min | 40.6 min |
| Cold start, first wave | 66 s | 2–6 s |
| Cost of the run | ≈ $0.04 | $0.30 |

Three runs failed before it, each on an image difference from `ubuntu-latest`:
1. **`~/.orun` owned by root (#13).** `install -d` owns only the leaf directory.
2. **Hosted-saved caches restored to the wrong path (#14).** `actions/cache` stores paths relative to the workspace.
3. **The `_work` symlink broke checkout (#15, #16).** checkout v6 matches `includeIf gitdir` against the real path, so the fix rewrites the JIT `workFolder` to `/home/runner/work`.

The trial ran with `max-parallel: 5`. At 8, 3 of 17 webhook deliveries were throttled at the account's 10 concurrent Lambda executions.

### The cutover (NR4, 2026-09-30)

- **Burst, synthetic.** 50 jobs, 50/50 passed. The first sweeper build rounded 19-digit delivery ids (#21), so 33 jobs waited about 19 minutes until the fix went out.
- **Burst, orun-cloud.** [orun-cloud#1732](https://github.com/sourceplane/orun-cloud/pull/1732) carried temporary markers in `sdk`, `policy-engine` and `db`, which select 51 lanes. It passed 51/51 twice.
  - The first run was flattered by about 48 idle runners that the sweeper had launched by redelivering the same deliveries three minutes running. #23 now checks the job is still queued and backs off per job.
  - The cold run: 51/51 passed, `plan` to first step at p50 74 s and p90 88 s, worst 245 s. Lane run time p50 94 s, 87.9 runner-minutes, workflow 6.1 min, about $0.12 against $0.67 at hosted rates.
- **Cutover.** The markers were removed and #1732 merged with a `ci.yml`-only diff: `run` lanes on `[self-hosted, linux, x64, nimbus]` with no `max-parallel`. `plan`, `deps-cache`, `work-sync` and `run-local` stay hosted. To break glass, set `runs-on` back to `ubuntu-latest`.
