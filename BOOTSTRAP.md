# Bootstrapping a nimbus-runners fleet

The fleet deploys itself from CI. Four things need a person, because no API can do them unattended: the AWS role, the GitHub App, its credentials, and its webhook URL.

## 1. The AWS role (once per account)

The fleet's CI assumes one role over GitHub OIDC, and that role owns nothing else. For sourceplane it is `github-sourceplane-nimbus-runners`, created by [sourceplane/aws-admin](https://github.com/sourceplane/aws-admin) (`domains/access/github-repositories/sourceplane-nimbus-runners`) together with the permissions boundary `nimbus-runners-boundary`. Every role the fleet creates must carry that boundary. Set the role's ARN as `awsRoleArn` in `intent.yaml`.

## 2. The GitHub App (once per fleet)

Create it in the organization: **Settings → Developer settings → GitHub Apps → New GitHub App**.

| Setting | Value |
|---|---|
| Name | e.g. `sourceplane-nimbus-runners` |
| Homepage URL | this repository |
| Webhook | Active. URL: any placeholder for now (step 4). Secret: a random string (`openssl rand -hex 32`) |
| Repository permissions | Actions: **Read-only** · Metadata: **Read-only** |
| Organization permissions | Self-hosted runners: **Read and write** |
| Subscribe to events | **Workflow job** |
| Where can it be installed | Only on this account |

Then:
- **Generate a private key** (a `.pem` downloads).
- **Install App → the organization → Only select repositories:** the repositories in `allowed_repositories` (`infra/fleet/terraform/local.tf`).

## 3. The credentials, into SSM

In AWS CloudShell (us-east-1), signed in to the fleet's account. Upload the `.pem` first.

```bash
aws ssm put-parameter --name /nimbus-runners/github-app/id --type String --value "<app id>"
aws ssm put-parameter --name /nimbus-runners/github-app/key_base64 --type SecureString --value "$(base64 -w0 < <app>.private-key.pem)"
read -rs SECRET && aws ssm put-parameter --name /nimbus-runners/github-app/webhook_secret --type SecureString --value "$SECRET"; unset SECRET
rm <app>.private-key.pem
```

These values never pass through Terraform state, CI or Orun. The module's lambdas read them at runtime.

## 4. The webhook URL

After the first apply on `main`, the `fleet · prod · Terraform` lane prints the `webhook_endpoint` output. Set it as the App's webhook URL. **Advanced → Recent deliveries** should show `202` for the next queued job.

## 5. The quotas

- **Spot vCPUs.** A 100-runner burst needs 200 vCPUs of **All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests** (`L-34B43A08`, Service Quotas → Amazon EC2). Request more if it is lower.
- **Lambda concurrency.** A fresh account allows 10 concurrent executions (`L-B99A9384`, Service Quotas → AWS Lambda). The fleet reserves none and works at 10, but it shares that pool with every other function in the account. Request 1,000 (the standard default).

## 6. The image

The `Runner AMI` workflow builds the image and writes its id to `/nimbus-runners/ami-id`. Until it has run once, the launch template points at stock Ubuntu, and a runner will not start.

## Using the fleet

```yaml
runs-on: [self-hosted, linux, x64, nimbus]
```

Only repositories in `allowed_repositories` that also have the App installed get runners. This repository's own workflows always run on GitHub-hosted runners.
