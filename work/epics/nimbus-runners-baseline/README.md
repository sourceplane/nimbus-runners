# Epic: nimbus-runners-baseline (NR)

**GitHub-hosted runners cost sourceplane/orun-cloud $299 in the last 30 days, and the pace doubled in the last week. Nothing in the Orun catalogue lets a workspace run its own cheaper fleet. This epic makes one baseline, `nimbus-runners`, that stands up ephemeral, spot-priced, self-hosted GitHub Actions runners in the adopter's own AWS account with the adopter's own GitHub App. It deploys through Orun like any other product repo: stack-granite's `terraform-aws` composition, AWS credentials assumed over GitHub OIDC, state held by Orun. The design idea that makes it cheap is to pay only for a job while it runs. Each job gets one spot instance booted from a prebuilt image, which terminates when the job ends. The subnets are public, so there is no NAT gateway, and there is no warm pool.**

This is stage 1 of two. Dispatch here is GitHub's own: every queued job that carries the fleet's labels boots a runner, whether or not its orun dependencies are done. Stage 2, [`sourceplane/orun-managed-runners`](https://github.com/sourceplane/orun-managed-runners), puts the Orun control plane in front of this fleet so that a job boots a runner only when it can run. Stage 2 consumes this baseline unchanged, apart from two module flags.

The fleet design and cost model were first written as [sourceplane/aws-admin#33](https://github.com/sourceplane/aws-admin/pull/33). That PR is superseded by this epic, and aws-admin keeps only the IAM and OIDC roles.

## Status

| Field | Value |
|-------|-------|
| Status | Draft |
| Cluster | **NR** (NR0–NR5) |
| Owner(s) | `infra/network`, `infra/runners`, `infra/budget` (Terraform, stack-granite `terraform-aws`) · `image/` (Packer) · `blueprint.yaml` + `repo-blueprint.yaml` (the baseline) |
| Builds on | `github-aws-runners/terraform-aws-github-runner` 7.11.0 · `stack-granite` 0.1.0 `terraform-aws` · aws-admin's GitHub OIDC provider and per-repo roles |
| Changes | A new repository and baseline. orun-cloud changes one `runs-on` line in NR4. aws-admin gains one role component in NR1 and closes #33. |
| Decisions locked | (1) Ephemeral JIT runners, one job per spot instance. (2) Public subnets and no NAT; no ingress; SSM for debugging. (3) A dedicated GitHub App per adopter, with its credentials in SSM and never in Terraform state. (4) State and credentials come from stack-granite (Orun HTTP state, OIDC-assumed role); no S3 bucket and no static keys. (5) This repo's own CI never runs on the fleet. |
| Gate | NR2 is the first thing that costs money. NR4 is the first user-visible change. |
| Shipped as | |

## Feasibility, verified before this spec (2026-09-29)

| Claim | How it was checked | Result |
|---|---|---|
| The module, the network and the budget compose | `terraform init` and `validate` against module 7.11.0, aws provider 6.66 | valid |
| The prebuilt image builds from the module's own start and install scripts | `packer validate` against the templates at tag v7.11.0 | valid |
| The lambdas can deploy with no pre-download step | release assets are under 1 MB each (`webhook`, `runners`, `termination-watcher`), fetched with the `http` data source and staged in S3 | viable |
| orun discovers a Terraform component in this layout | `orun plan --env dev` in aws-admin#33 listed `github-runners` | yes |
| stack-granite can be pinned from GHCR | `GET /orgs/sourceplane/packages/container/stack-granite` | **404, not published.** NR1 publishes it; see NR-A |
| orun can load a composition from git | composition sources are `dir`, `archive`, `oci` (orun `internal/composition/registry.go:601-605`) | no. The fallback is a vendored `dir` |
| Cost at orun-cloud's volume | 15,331 jobs and 40,823 runner-minutes over 30 days, from the Actions API | $48–54/month on x86 spot vs $299 hosted. The last 7 days' pace is $96–105 (see NR-B) |

## Read order

1. `design.md`: the fleet, the components, the GitHub App, state and credentials, the image, the baseline card, and what is out of scope
2. `implementation-plan.md`: the milestones and what "done" means for each
3. `risks-and-open-questions.md`: what could go wrong and what was decided
4. `IMPLEMENTATION-STATUS.md`: what actually shipped, kept distinct from intent

## Milestones at a glance

| Milestone | What it lands | Done when |
|---|---|---|
| NR0 — the spec | this doc set, the work tree, and the CI that syncs it | merged, and `orun work sync` created the epic |
| NR1 — foundations | stack-granite published; the aws-admin role; compositions pinned | `orun plan` loads `terraform-aws`, and a PR lane assumes the plan role |
| NR2 — the fleet | the network, lambdas, runners and budget components, applied to `prod` | a labelled test job runs on spot and its instance terminates. A 100-job burst drains |
| NR3 — the image | the Packer image and the Runner AMI workflow | p50 launch-to-job-start is under 60s |
| NR4 — orun-cloud on the fleet | orun-cloud's `run` matrix moved | 7 clean days, with run-rate measured against the model |
| NR5 — the baseline | the blueprint card, build phases, rebrand, tag and registration | `orun baseline new nimbus-runners` builds a fresh fleet |
