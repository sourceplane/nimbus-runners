# nimbus-runners-baseline (NR) — Implementation status

As-built ≠ intent. This file records what actually shipped, and every place the code departed from `design.md`.

| Milestone | State | PR |
|---|---|---|
| NR0 — the spec | ✅ merged, synced | [#1](https://github.com/sourceplane/nimbus-runners/pull/1), [#2](https://github.com/sourceplane/nimbus-runners/pull/2) |
| NR1 — foundations | ✅ | NR-2; [stack-granite#1](https://github.com/sourceplane/stack-granite/pull/1) + tag v0.1.0; [aws-admin#35](https://github.com/sourceplane/aws-admin/pull/35) |
| NR2 — the fleet | ✅ applied to prod; App `sourceplane-nimbus-runners` installed | NR-3: [#4](https://github.com/sourceplane/nimbus-runners/pull/4), [#5](https://github.com/sourceplane/nimbus-runners/pull/5), [#6](https://github.com/sourceplane/nimbus-runners/pull/6) |
| NR3 — the image | image live; burst test waits on the Lambda quota | NR-4: [#7](https://github.com/sourceplane/nimbus-runners/pull/7), [#8](https://github.com/sourceplane/nimbus-runners/pull/8), [#10](https://github.com/sourceplane/nimbus-runners/pull/10), [#13](https://github.com/sourceplane/nimbus-runners/pull/13), [#14](https://github.com/sourceplane/nimbus-runners/pull/14), [#15](https://github.com/sourceplane/nimbus-runners/pull/15), [#16](https://github.com/sourceplane/nimbus-runners/pull/16) |
| NR4 — orun-cloud on the fleet | **cut over 2026-09-30**; 7-day watch running | NR-5: [orun-cloud#1732](https://github.com/sourceplane/orun-cloud/pull/1732) (merged), trial [#1730](https://github.com/sourceplane/orun-cloud/pull/1730) (closed) |
| NR5 — the baseline | the README positions the repository as the standalone self-hosted option (2026-10-01); `baseline-v1` tag and registration still open | NR-6 |

## Measurements

| Measure | Target | Measured |
|---|---|---|
| p50 launch-to-job-start | < 60 s | ≈ 55–60 s. Queue-to-start is 87 s p50 over 15 lanes (2026-09-30), which includes the 10 s webhook delay, the queued check and CreateFleet |
| 100-job burst, worst wait for a runner | < 3 min | 50-job burst: 50/50 passed. orun-cloud cold 51-lane run: 51/51 passed, 47 started within 90 s of `plan` (p50 74 s), worst 245 s. **Not met at 128 lanes (2026-10-14):** every lane got a runner, but only 61 within 3 min, and the worst waited 17 min (below) |
| Spot vCPU quota `L-34B43A08` | ≥ 200 | 200 ✅ |
| Lambda concurrency `L-B99A9384` | 1,000 | 1,500 ✅ (2026-10-14). No lane is lost to a throttled webhook any more; the burst still arrives in waves (below) |
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

### The burst after the Lambda quota (2026-10-14)

[sourceplane/orun-cloud#1869](https://github.com/sourceplane/orun-cloud/pull/1869) ran orun-cloud's widest pull-request fan-out, a full verify of 128 lanes, once the account's Lambda concurrency was 1,500. It is compared with the last full verify at the old quota of 10, on 2026-10-05 ([#1826](https://github.com/sourceplane/orun-cloud/pull/1826), [run 37269666394](https://github.com/sourceplane/orun-cloud/actions/runs/37269666394)).

| 128 lanes, from `plan` finishing | 2026-10-05, quota 10 | 2026-10-14, quota 1,500 ([run 38523921655](https://github.com/sourceplane/orun-cloud/actions/runs/38523921655)) |
|---|---|---|
| Lanes that got a runner | 105; 23 sat queued for 69 min until the run was cancelled | 128 |
| Started within 90 s / 3 min / 5 min | 47 / 48 / 48 | 61 / 61 / 99 |
| Queue to start, p50 / p90 / worst | 5.3 / 16.6 / 18.0 min | 4.2 / 7.4 / 17.2 min |
| Most lanes running at once | 48 | 61 (68 across the fleet, other pull requests included) |
| Lane run time, p50 / p90 | 92 / 209 s | 92 / 217 s |
| `plan` to the last lane finishing | — (lanes lost) | 21.6 min |
| Runner-minutes (GitHub job time) | — | 266.6 |

The quota fixed the lost lanes. It did not fix the waves:

- **The first scale-up pass launches 40 to 60 runners, not 128.** 61 lanes started 71–83 s after they were queued. Nothing else started until 06:53, about four minutes in, when 38 arrived together (the `job_retry` re-check, 120 s delay, plus boot). The last 29 trickled in over the next 13 minutes. A second burst later that morning, 56 lanes, had 50 running within 3 min, and its last lane waited 6.6 min. The 2026-10-05 run shows the same shape: 47, then a trickle.
- **Neither cap was reached.** At most 68 runners were busy across the fleet (`runners_maximum_count` is 100, the spot quota is 200 vCPU, 100 instances). At 06:53, 11 of the run's lanes were running and 67 were queued; from 06:59 to 07:02, 3 to 5 were running and 10 were still queued.
- **Probably not the webhook.** At 1,500 the webhook lambda has headroom for the whole burst, and the second wave came on `job_retry`'s 120 s beat, not on the sweeper's one-minute beat. The likelier loss is between SQS and a registered runner: scale-up, CreateFleet, or the JIT config. The GitHub App's delivery log would settle it.
- **It costs wall-clock.** The longest lane (`web-console-perf-budgets`, 15 min of work) waited 6m46s for a runner, so the run took 21.6 min instead of about 16.5.

**The cause ([#27](https://github.com/sourceplane/nimbus-runners/issues/27)): the scale-up lambda timed out part-way through its batches.**
- **What one invocation does.** It works through its SQS batch one message at a time: the job-queued check per message, the runner count, one CreateFleet, then per runner a GitHub `generate-jitconfig` POST, an SSM `PutParameter` and a 25 ms pause (module v7.11.0, `scale-up.ts` and `github-runner.ts`).
- **Why it ran out of time.** The fleet raised the batch from the module's 10 to 20 and kept the module's 30 s timeout, so a full batch could outrun its lambda.
- **What a timed-out batch leaves behind.**
  - Its instances are already launched but only partly configured. They never register, yet they count against `runners_maximum_count` until scale-down reaps them after `runner_boot_time_in_minutes` (4).
  - Its messages return to the queue after the 30 s visibility timeout. The retries find the cap full of unconfigured instances.
- **Why it looked like waves.** A JIT failure inside a batch that completes is handled cleanly: the module terminates the unconfigured instance and retries the message. Only a timeout skips that.

**The fix (#26):**
- `lambda_event_source_mapping_batch_size` goes back to 10.
- `runners_scale_up_lambda_timeout` goes to 120 s; the build queue's visibility timeout follows it.
- `job_retry` stays at 120 s. A re-check shorter than a runner's boot (~70 s) would find the job still queued and launch it a second runner.

Packing jobs onto fewer runners with orun lanes (orun v2.76+) works around the waves, because a smaller fan-out fits inside the first pass. 56 lanes of one to three jobs, two at a time, finished the same full verify in 16.9 min on 207.6 runner-minutes. orun-cloud is not adopting lanes yet; the reasons are in #1869.

