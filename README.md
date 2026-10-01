# nimbus-runners

Your own GitHub Actions runners, in your own AWS account, on spot instances: one fresh VM per job, gone when the job ends.

This is an [Orun](https://orunbase.com) baseline built on [github-aws-runners/terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner). It is the self-hosted option, and it stands alone: GitHub tells the fleet a job is queued, the fleet boots a runner, the job runs. Nothing else is in that path. No Orunbase service, no shared pool, no credential that leaves your account.

```
GitHub ── workflow_job ──► API Gateway ──► webhook λ ──► SQS ──► scale-up λ ──► EC2 spot (1 job, then terminated)
   ▲                                                                                │
   └──────────────────────── runner registers with a single-use JIT config ◄────────┘
```

## What you get

| | |
|---|---|
| **Isolation** | One ephemeral instance per job, registered with a single-use JIT config. No runner is reused. |
| **Cost** | About $0.0008 per runner-minute (2 vCPU / 8 GiB spot, EBS and IPv4 included) against $0.006 on GitHub-hosted. Idle cost is about $4 a month. A monthly AWS budget alarm is part of the fleet. |
| **Burst** | 100 runners by default, across seven instance types and five availability zones, spot with on-demand fallback when a pool is empty. |
| **Start time** | A prebuilt image (`image/`) with the runner, Docker and Node baked in. No user data, no downloads at boot. |
| **Missed webhooks** | GitHub never retries a failed delivery. A sweeper re-requests failed `workflow_job` deliveries for jobs that are still queued. |
| **Blast radius** | Every role carries a permissions boundary; the deploy role can only touch resources under the fleet's prefix. The GitHub App key lives in SSM and never passes through Terraform state or CI. |

Measured on [sourceplane/orun-cloud](https://github.com/sourceplane/orun-cloud), which has run its CI lanes here since 2026-09-30:

| Measure | Result |
|---|---|
| 50-job burst | 50 of 50 passed |
| 51-lane verify, cold | 51 of 51 passed; from the plan finishing to a lane's first step, p50 74 s |
| A production main push (17 lanes) | about $0.07 on the fleet against $0.46 on GitHub-hosted |

## Use it

1. **Fork or instantiate** this repository and set your prefix, labels, allowed repositories, runner cap and budget in [`infra/fleet/terraform/local.tf`](infra/fleet/terraform/local.tf).
2. **Follow [`BOOTSTRAP.md`](BOOTSTRAP.md)**: the AWS role, your GitHub App, its three values into SSM, the webhook URL, the quotas, the image.
3. **Point a workflow at it:**

   ```yaml
   runs-on: [self-hosted, linux, x64, nimbus]
   ```

The fleet is one Terraform root (`infra/fleet/terraform`). This repository deploys it with `orun` through the [`stack-granite`](https://github.com/sourceplane/stack-granite) `terraform-aws` composition, with GitHub OIDC for AWS and no long-lived keys; the root is plain Terraform and applies with any backend if you would rather run it yourself.

## What is in here

| Path | What |
|---|---|
| `infra/fleet/` | the fleet: network, runner module, lambdas, budget, the webhook-redelivery sweeper |
| `image/` | the Packer image and its provisioning script |
| `.github/workflows/runner-ami.yaml` | builds the image and publishes its id to SSM |
| `BOOTSTRAP.md` | the steps that need a person |
| `work/` | the epic, design and as-built status ([`work/epics/nimbus-runners-baseline/`](work/epics/nimbus-runners-baseline/)) |

## Self-hosted or managed

| | nimbus-runners (this repository) | Orunbase managed runners |
|---|---|---|
| Where jobs run | your AWS account | an Orunbase-operated cell |
| GitHub App | yours | the Orunbase App |
| Who decides when a runner starts | GitHub's webhook, the moment a job is queued | Orunbase, when the plan says the job can run |
| What you operate | the fleet, its image, its quotas | nothing |
| Depends on Orunbase at run time | no | yes |

Choose this one when you want the runners inside your own boundary and nothing between GitHub and your account. It does not change when managed runners change, and it never requires them.
