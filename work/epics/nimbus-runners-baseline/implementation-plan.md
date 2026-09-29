# nimbus-runners-baseline — implementation plan

Milestones land in order. Each is one or more tasks, and each task is one pull request on an `orun/<KEY>-<slug>` branch with an `Orun-Task` trailer. A PR merges when every check is green. A milestone's task keys are added to `epic.yaml`, with their contracts under `work/tasks/`, in the PR that starts the milestone. `orun work sync` then reconciles them. A milestone is marked ✅ here when its "done when" list is true, and recorded in `IMPLEMENTATION-STATUS.md`.

## NR0 — the spec

This doc set, `epic.yaml`, the `NR-1` contract, `intent.yaml` with its `work:` section, and the CI that runs `orun work check` on pull requests and `orun work sync` on main.

**Done when**
- the five documents and `epic.yaml` are on `main`
- the `work-sync` job on that push is green, and workspace `nimbus-runners` shows the epic with six milestones and `NR-1`

## NR1 — foundations

Everything the fleet needs before it can plan. Two of the pieces are cross-repository.

- **stack-granite.** Enable its `release.yml` (it is under `.github/pending-workflows/`), publish `0.1.0` to `ghcr.io/sourceplane/stack-granite`, and record the digest. This lands as a PR in `sourceplane/stack-granite`, referenced from the NR task.
- **aws-admin.** Add `domains/access/github-repositories/sourceplane-nimbus-runners`: a plan role (PR and main) and a `prod` deploy role, with policies scoped to the fleet's resources by the `nimbus-` prefix and tag. Close aws-admin#33 with a link to this epic.
- **This repo.** Pin `compositions.sources` to `oci://ghcr.io/sourceplane/stack-granite:0.1.0@sha256:…` and bind `terraform-aws`. Add the CI `plan` and `run` jobs in stack-granite's shape.

**Done when**
- `orun plan --env prod` in this repo resolves the OCI stack and loads `terraform-aws`
- a pull request's validate lane passes, and a `plan-only` lane assumes `github-sourceplane-nimbus-runners-plan` over OIDC
- aws-admin#33 is closed as superseded

## NR2 — the fleet

Port the Terraform from aws-admin#33 into `infra/network`, `infra/runners` and `infra/budget` on `terraform-aws`. Replace the S3 backend with the HTTP backend, and the explicit SSM prefix with the baseline inputs. Wire network outputs to runners through `secretOutputs` / `secretEnv`. Write `BOOTSTRAP.md` for the GitHub App and the SSM parameters. Apply to `prod` in the sourceplane account. Until NR3 lands, the image parameter holds a stock Ubuntu id, so the smoke test waits for NR3's first image.

**Done when**
- `infra/*` plans clean on a PR and applies on main
- the `webhook_endpoint` output is set on the sourceplane nimbus-runners App, and a delivery to it answers 202
- the spot vCPU quota `L-34B43A08` is at least 200, and this is recorded in `IMPLEMENTATION-STATUS.md`

## NR3 — the image

Move `image/` and `runner-ami.yaml` from aws-admin#33, switching from static keys to the deploy role over OIDC. Build the first image.

**Done when**
- the workflow writes `/<prefix>/ami-id`, and a second run deregisters images beyond the newest two
- a test workflow in an allowed repository on `runs-on: [self-hosted, linux, x64, nimbus]` passes, and its instance is terminated within 60 seconds of the job ending
- p50 launch-to-job-start over 20 test jobs is under 60 seconds
- a 100-job matrix drains with no job waiting more than 3 minutes for a runner

## NR4 — orun-cloud on the fleet

In `sourceplane/orun-cloud`, move the `run` matrix to `runs-on: [self-hosted, linux, x64, nimbus]`. `plan`, `deps-cache` and `work-sync` stay on GitHub-hosted runners for a week, then move.

**Done when**
- seven consecutive days of orun-cloud CI run on the fleet with no failure attributable to the fleet
- `IMPLEMENTATION-STATUS.md` records measured instance-hours, spot price and dollars against §6 of the design

## NR5 — the baseline

Write `blueprint.yaml` and `repo-blueprint.yaml`, rebrand tooling, the tests and `tag.yml`. Cut `baseline-v1`, register it, and add the public registry row in orun-cloud.

**Done when**
- `orun baseline check nimbus-runners` is green for a fresh workspace
- `orun baseline new nimbus-runners --local` builds a fleet in a test account, stopping at the documented GitHub App checkpoint and resuming after it
- the registry row is merged in orun-cloud, and the baseline shows in the catalogue

## Sequencing note

- **NR1 gates everything.** Without a published stack there is nothing to plan, and without the role nothing can apply.
- **NR2 and NR3 can overlap once NR1 is in:** the image workflow needs only the deploy role and the network.
- **NR4 waits for NR3's smoke test and burst test.** orun-cloud must not find the fleet's problems for it.
- **NR5 is last,** because the baseline packages what NR2–NR4 proved.
- **Stage 2** (`orun-managed-runners`) can start its control-plane work in parallel. Its end-to-end milestone needs NR3.
