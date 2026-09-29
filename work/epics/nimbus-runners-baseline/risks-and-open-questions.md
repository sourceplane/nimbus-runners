# nimbus-runners-baseline — risks and open questions

Each entry is a letter, a title, and a state: **RISK** (open, with a mitigation), **RESOLVED** (decided; says what and why), **ACCEPTED** (a cost we carry knowingly), **SETTLED** (decided for now; revisit on a stated cadence).

## NR-A — stack-granite is not published (RISK, mitigated)

`GET /orgs/sourceplane/packages/container/stack-granite` answers 404. The stack exists at git tag `v0.1.0`, but its release workflow sits under `.github/pending-workflows/`, and orun cannot load a composition from git (sources are `dir`, `archive` and `oci`). NR1 publishes it.

If publishing stalls, this repo vendors `compositions/terraform-aws` as a `dir` source pinned to the stack's commit. That fallback costs a later swap to OCI, but the component contract is the same.

## NR-B — cost above $55 at the current pace (RISK)

The 30-day volume fits ($48–54). The last seven days ran 2.3× faster ($96–105). The budget alerts, but it does not cap spend. Mitigations, in order:
1. Stage 2 removes the minutes lanes spend waiting while holding a runner. orun-cloud's comments put waiting at ~70% of PR minutes before advisory dependencies; on main it is unmeasured.
2. A 4 GiB class for light deploy lanes.
3. Graviton.

The NR4 measurement decides which one comes next.

## NR-C — GitHub's self-hosted platform fee (ACCEPTED)

GitHub announced a $0.002/min charge for self-hosted runners in private repositories, then postponed it on 2025-12-17. It has not taken effect. If it lands, it adds about $82/month at the 30-day volume, still well under hosted pricing. Carried knowingly.

## NR-D — image drift from `ubuntu-latest` (RISK, mitigated)

A lane may expect a tool the hosted image ships. NR4 moves only the `run` matrix first. A missing tool is a one-line change in `provision.sh`, followed by an image rebuild, with no Terraform apply.

## NR-E — spot capacity and quota (RISK, mitigated)

A 100-runner burst needs 200 spot vCPUs. It draws on seven instance types across five AZs, and falls back to on-demand on `InsufficientInstanceCapacity`. The quota is checked in NR2 and recorded in the status file.

## NR-F — where the GitHub App credentials live (RESOLVED)

The options were baseline inputs flowing to Terraform, Orun secrets flowing through `secretEnv`, or SSM written by the operator. Both of the first two put the private key in Terraform state. Decided: SSM, read by the module's `*_ssm` inputs. The key never touches state, CI or Orun.

## NR-G — public repository, self-hosted fleet (RESOLVED)

This repository is public. Its own workflows always run on GitHub-hosted runners, and the fleet serves only `allowedRepositories`. The App is installed on selected repositories, and the fleet's runner group is restricted to them. A fork PR to this repository can never reach a fleet instance.

## NR-H — one environment (SETTLED)

A fleet is account-wide infrastructure for CI, so there is no stage/prod pair of fleets. Pull requests run `plan-only` against `prod`, and main applies. Revisit if an adopter needs a canary fleet. The likely answer then is a second instance of the baseline with its own labels, not a second environment.

## NR-I — the Orunbase AWS integration is dormant (ACCEPTED)

The integrations worker lists AWS as `status: roadmap`, so the baseline cannot `integrations/reconcile` AWS, and `requires.integrations` is `[github]`. The adopter supplies `awsRoleArn`. When the integration ships, the role becomes a brokered connection and the input goes away.

## NR-J — superseding aws-admin#33 (RESOLVED)

The fleet was first written as a component in aws-admin. Decided on 2026-09-29: the fleet lives in this baseline, and aws-admin keeps only IAM and OIDC. #33 is closed in NR1, and its Terraform, image and workflow are ported in NR2 and NR3.
