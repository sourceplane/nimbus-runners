# nimbus-runners-baseline — design

## 0. The shape, in one paragraph

A GitHub App owned by the adopter sends `workflow_job` events to an API Gateway endpoint in the adopter's AWS account. The module's webhook lambda filters them by repository and labels, and puts them on an SQS queue with a short delay. The scale-up lambda checks that the job is still queued, writes a just-in-time (JIT) runner config to SSM, and calls EC2 CreateFleet for one spot instance. The instance boots a prebuilt image, reads its JIT config, runs exactly one job, and terminates itself. Everything is deployed by orun from this repository, through stack-granite's `terraform-aws` composition. Every name, label, instance type, cap and budget comes from the baseline's inputs.

## 1. The fleet

| Concern | Decision | Why |
|---|---|---|
| Runner lifecycle | Ephemeral, JIT-registered, one job per instance (`enable_ephemeral_runners`, `enable_jit_config`) | Jobs carry deploy credentials, so nothing survives between jobs. Nothing is paid between bursts. |
| Capacity | Spot, `price-capacity-optimized`, seven 2 vCPU / 8 GiB x86 types across five AZs. On-demand only on `InsufficientInstanceCapacity` | Deep pools for a 100-instance burst at about 40% of the on-demand price. |
| Instance families | `m7i-flex`, `m6a`, `m5a`, `m6i`, `m5`, `m7i`, `m7a` `.large`; no T-family | Matches the private-repo `ubuntu-latest` shape. T3 runs out of CPU credits or bills unlimited-mode surcharges under CI load. |
| Cap | `runners_maximum_count = 100` (input `maxRunners`); scale-up concurrency 5; batch 20 | Absorbs a full orun-cloud verify. Lanes above the cap queue; they are not dropped. |
| Cancelled jobs | `delay_webhook_event = 10`, `enable_job_queued_check = true` | Superseded PR runs are cancelled by the consumer's concurrency group and never boot. |
| Labels | `[self-hosted, linux, x64, nimbus]` (input `runnerLabels`) | One label selects the fleet. Stage 2 adds per-job `ghr-*` labels without changing this set. |
| Spot interruptions | termination watcher on, with runner deregistration | An interrupted job fails fast instead of hanging. orun's `--retry` resumes it. |
| Debugging | `enable_ssm_on_runners` | No SSH keys and no ingress. |

Stage 2 flips two module inputs and nothing else: `enable_dynamic_labels = true` and `delay_webhook_event = 0`. Both are baseline inputs from NR2 onward, defaulting to `false` and `10`.

## 2. Components

Each component is a `terraform-aws` component under `infra/`, subscribed to `prod`. The profile is `plan-only` on pull requests and `apply` on `github-push-main`.

| Component | Resources | Depends on |
|---|---|---|
| `infra/network` | VPC `10.80.0.0/16`, five public `/20` subnets, an internet gateway, a free S3 gateway endpoint, and a locked default security group | — |
| `infra/runners` | The module; an S3 bucket for the pinned lambda zips (`http` data source → `aws_s3_object`); the SSM parameter `/<prefix>/ami-id` (value owned by the image workflow) | `network` (subnet ids via `secretOutputs` → `secretEnv`) |
| `infra/budget` | An AWS Budget over EC2, EC2-Other, VPC, Lambda, API Gateway, SQS and CloudWatch, with alerts at 80% actual and 100% forecast | — |

Cross-component values travel through stack-granite's `secretOutputs` / `secretEnv` channel, not through remote-state data sources. The network publishes `VPC_ID` and `PUBLIC_SUBNET_IDS`, and the runners component reads them as `TF_VAR_*`.

Outputs that operators need: `webhook_endpoint` (set on the GitHub App), `runner_labels` and `ami_ssm_parameter_name`.

## 3. The GitHub App

Each adopter creates one App. It is never the Orunbase App: this fleet must work with no Orun control plane in the dispatch path.

| Setting | Value |
|---|---|
| Repository permissions | `Actions: Read-only` (the queued check), `Metadata: Read-only` |
| Organization permissions | `Self-hosted runners: Read & write` (JIT registration) |
| Events | `Workflow job` |
| Webhook URL | the `webhook_endpoint` output |
| Installation | selected repositories; the module's `repository_white_list` (input `allowedRepositories`) is the second fence |

The App id, private key and webhook secret are written by the operator to `/<prefix>/github-app/{id,key_base64,webhook_secret}` in SSM, as SecureString for the last two. The module reads them through its `*_ssm` inputs, so they never enter Terraform state, the Orun secret store, or CI. `BOOTSTRAP.md` carries the exact steps.

## 4. State and AWS credentials

- **State** lives in Orun's HTTP backend (stack-granite's `backend "http" {}`), addressed by workspace, project, environment and component. There is no S3 bucket or DynamoDB table.
- **AWS credentials** come from GitHub OIDC. stack-granite assumes `awsRoleArn` before any credentialed step. The role is owned by `sourceplane/aws-admin`. In NR1 it is a new component, `domains/access/github-repositories/sourceplane-nimbus-runners`, with a plan role for PRs and main and a deploy role for the `prod` environment.
- For an adopter outside sourceplane, `awsRoleArn` is a blueprint input. `BOOTSTRAP.md` gives the trust policy for creating the role by hand.

## 5. The image

- **Build.** Packer, from `image/github-runner.pkr.hcl` on Ubuntu 24.04. It bakes in the actions runner, Docker CE (buildx and compose), the AWS CLI, node 20 and 22 in `/opt/hostedtoolcache` (with `.complete` markers), corepack/pnpm, and Chromium's system libraries for Playwright. It also creates a `runner` user at `/home/runner` with passwordless sudo, and turns off apt timers and unattended-upgrades. The module's `start-runner.sh` is installed as a per-boot script.
- **Workflow.** `.github/workflows/runner-ami.yaml` runs on image changes, weekly, and on dispatch. It writes the new id to `/<prefix>/ami-id` and keeps the newest two images. The launch template resolves `resolve:ssm:/<prefix>/ami-id` at every launch, so a new image needs no Terraform apply.
- **Credentials.** The workflow assumes the deploy role over OIDC; it has no static keys.
- **Boot target.** p50 launch-to-job-start under 60 seconds. There is no user data and no binaries syncer.

## 6. Cost model and guardrails

Per job, the instance runs for the job's own minutes plus the boot and teardown overhead, billed with a 60-second minimum. On top of that come a 40 GB gp3 volume ($0.0044/h), a public IPv4 ($0.005/h) and about $4/month of fixed costs: lambdas, API Gateway, SQS, 7-day logs and two AMI snapshots.

| orun-cloud volume | x86 spot $0.038/h, 1.0–1.5 min overhead | GitHub-hosted |
|---|---|---|
| 30-day actual: 40,823 min, 15,331 jobs | $48–54 | $299 |
| last 7 days' pace: 92,723 min, 23,156 jobs | $96–105 | $629 |

The budget (`infra/budget`, input `monthlyBudgetUsd`, default 55) alerts at 80% actual and 100% forecast. The cap bounds the burst, not the month. Beyond the budget, the levers are stage 2 (it removes lanes that wait while holding a runner), a 4 GiB class for light lanes, and Graviton.

## 7. The baseline

The baseline follows the cirrus shape.

- **`blueprint.yaml`** is the card.
  - `requires.integrations: [github]`. There is no AWS integration, because the Orunbase AWS provider is still on the roadmap.
  - Inputs:
    - `reponame` (from `repo.name`) and `githuborg` (from `repo.owner`)
    - `orunWorkspace`
    - `awsRegion` and `awsRoleArn`
    - `runnerLabels`, `instanceTypes`, `maxRunners`, `monthlyBudgetUsd`
    - `allowedRepositories`
  - `programme.epicSlug: infra-baselining`
- **`repo-blueprint.yaml`** has three phases:
  1. `01-scaffold`: `task/ensure`, rebrand, `repo/ensure`, `pr/land`
  2. `02-fleet`: the `infra/*` modules, `pr/land`, `run/watch`
  3. `03-image`: the Packer workflow and `run/watch`

  The GitHub App steps are an operator checkpoint named in `BOOTSTRAP.md`, because no Orun action can create a GitHub App.
- **Around it:**
  - `tooling/rebrand` with `.rebrand/values.json`
  - `testing/manifest.test.sh` and `tag-gate.sh`
  - `.github/workflows/tag.yml`, which cuts `baseline-vN`

  Registration is `orun baseline register nimbus-runners --source-repo sourceplane/nimbus-runners --tag baseline-v1 --manifest blueprint.yaml --requires github`. It then gets a public row in orun-cloud's `infra/baselines-registry/baselines.yaml`.

## 8. This repository's CI

- **On pull requests:** `orun work check`, then `orun plan --changed` with the `plan-only` profile (from NR1).
- **On main:** `orun work sync`, then the apply lanes.
- **Where it runs:** every job runs on GitHub-hosted runners. This repository is public, and a public repository's workflows, fork PRs included, must never reach a self-hosted fleet. The fleet serves the repositories in `allowedRepositories` only.

## 9. Out of scope

- **Orun-gated dispatch.** Releasing a job only when its dependencies are done is stage 2, `sourceplane/orun-managed-runners`.
- **Other runner types.** Windows, macOS and GPU runners, and Graviton, are a later input.
- **Warm pools.** Bursts are rare: 2 minutes in 30 days had 100 or more jobs running, so a warm pool costs more than it saves.
- **Replacing the GitHub Actions cache with S3.** The consumer's cache traffic is under the 100 GB/month egress free tier.
- **Creating the GitHub App automatically.** GitHub has no API for it without a manifest flow and a human, so it stays an operator step.
