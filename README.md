# cartergrove-me-infra

Terraform for the DigitalOcean infrastructure behind every `*.cartergrove.me`
project (games.cartergrove.me, stats.cartergrove.me, ...). Keeping it in one
repo lets projects share resources, like one managed Postgres cluster, without
stepping on each other.

## Layout

```
shared/            # root module: DNS zone, VPC, shared Postgres cluster, ...
projects/
  games/           # root module: games.cartergrove.me hub (one app, one path per game)
modules/           # reusable building blocks, called from root modules
bootstrap/         # one-time manual setup (state bucket, credentials)
```

**Root modules vs modules.** A *root module* is a directory you run `terraform`
in. It has its own backend and therefore its own state file, so `apply` in
`projects/games/` can only ever change what `projects/games/` manages. A plain
*module* (under `modules/`) is a reusable block that root modules call with
`module "x" { source = "../../modules/x" }`; it has no state of its own.

**Remote state.** Each root module stores its state in the
`cartergrove-me-tfstate` Spaces bucket, under its own key:

| Root module | State key |
| --- | --- |
| `shared/` | `shared/terraform.tfstate` |
| `projects/games/` | `projects/games/terraform.tfstate` |

**Sharing values.** Projects read `shared/`'s outputs (`region`, `domain`,
`vpc_id`, `vpc_ip_range`, `postgres`) with a read-only `data "terraform_remote_state"
"shared"` block. `shared/outputs.tf` is the contract: projects should rely only
on what it exports.

## Shared resources

`shared/` owns everything more than one project uses:

- **DNS zone** `cartergrove.me`. The zone itself only. Each project creates its
  own subdomain records (`games`, `stats`, …). Records that were already in the
  zone (the apex `A` and `www`) are not managed by Terraform and are left as is.
- **VPC** `shared-nyc3`. Apps attach to it to reach Postgres privately.
- **Postgres cluster** `shared-postgres`: PostgreSQL 18, `db-s-1vcpu-1gb`
  (1 vCPU, 1 GiB RAM, 10 GiB disk), single node, **$15/month** at the time of
  writing (see DigitalOcean's pricing page). There's no standby node: a node failure
  means a few minutes of downtime while DO replaces it. Projects get a database
  and user with [`modules/project-database`](modules/README.md).
- **Database firewall.** Only the VPC's range, plus any IPs in
  `postgres_trusted_ips`, may connect. It lives in `shared/` because DO keeps
  one trusted-source list per cluster (see the module README).

The zone and the cluster have `prevent_destroy`: Terraform refuses any plan that
would delete them. To really delete one, remove that line first.

### DNS: nameservers (one-time, done)

The registrar for `cartergrove.me` points at DigitalOcean's nameservers
`ns1.digitalocean.com`, `ns2.digitalocean.com` and `ns3.digitalocean.com`.
That's set in the registrar's control panel, not in Terraform. You'd only redo it
after transferring the domain. Check it with `nslookup -type=NS cartergrove.me`.

The zone already existed in DigitalOcean before Terraform, so `shared/main.tf`
*imports* it (an `import` block) instead of creating it. The first
`terraform plan` shows `1 to import`.

## Conventions

- **Naming:** resources are prefixed with their project: `games-downloads`,
  `games-hub`.
- **Tags:** every taggable resource gets `project:<name>` (`local.tags`).
- **DO Projects:** each project's resources are assigned to a DigitalOcean
  Project of the same name, so the control panel groups them. `shared/`'s
  resources go in the hand-made `cartergrove.me` project, which Terraform
  only reads (a `data` source) and doesn't manage.
- **Versions:** Terraform `~> 1.14` and provider `digitalocean/digitalocean`
  `~> 2.102`. The exact provider build is pinned by each root module's
  committed `.terraform.lock.hcl` (hashes for Windows, Linux and macOS arm64).
- **Secrets:** credentials come from environment variables only. State,
  `*.tfvars` and saved plans are git-ignored. State can contain secrets (e.g.
  database passwords), so it lives only in the private bucket.

## First-time setup

Follow [bootstrap/README.md](bootstrap/README.md): create the state bucket,
an API token and a Spaces key, and export them as environment variables.

## Running plan / apply (locally)

```bash
cd shared            # or projects/<name>
terraform init       # once per directory, and after changing providers/backend
terraform plan       # preview changes
terraform apply      # shows the plan again and asks before changing anything
```

Apply `shared/` before any project that reads its outputs.

## CI: plan and apply

[`.github/workflows/terraform.yml`](.github/workflows/terraform.yml) runs
Terraform in GitHub Actions. On a pull request, only root modules affected by
the change get a job.
[`.github/scripts/changed-roots.sh`](.github/scripts/changed-roots.sh)
decides: a root counts as affected if a file in its directory changed, if a
module it calls under `modules/` changed, or if anything under `.github/`
changed.

| Event | What runs |
| --- | --- |
| Pull request to `main` | `terraform fmt -check` (whole repo), then `validate` + `plan` per affected root. Each plan is posted as a PR comment and updated in place on later pushes. |
| Push to `main` (a merge) | A plan of **every** root against what was merged, in the run's **Summary**, then one `apply` job per root whose plan has changes ([`terraform-apply.yml`](.github/workflows/terraform-apply.yml)). Each waits for approval. |

**Approving an apply.** The apply jobs use the `production` environment, which
requires a reviewer. After a merge, open the run (**Actions → Terraform**),
read the plans in its summary, then **Review deployments → Approve and
deploy**. `shared` is applied first, as its own job, because projects read
its outputs. The projects' applies only start after it succeeds (or when
`shared` has no changes). Only approve after reading the plan.

The apply job plans once more and applies exactly that saved plan. It can't
reuse the plan you read: a saved plan can contain secrets, and a public repo's
artifacts are public. If something changed in between (e.g. a manual edit in
the control panel), the job log shows it.

**One apply per root at a time.** State locking is off (see
[bootstrap/README.md](bootstrap/README.md#note-no-state-locking)), so each
root's apply is in its own `concurrency` group: an apply from a later merge
waits for the running one (or the one waiting for approval). GitHub keeps
only one waiting run per group, so a third merge cancels the second. Nothing
is lost, because a merge plans every root rather than only the ones it
changed: the third run applies whatever the second would have, including in
roots the third merge didn't touch. This also picks up drift, and a change to
`shared` outputs that a project reads is applied to that project on the next
merge. The concurrency groups only cover CI, so don't run a local `apply`
while one is running in CI.

### One-time CI setup

1. **Secrets.** Under **Settings → Secrets and variables → Actions**, add
   repository secrets `DIGITALOCEAN_TOKEN`, `SPACES_ACCESS_KEY_ID` and
   `SPACES_SECRET_ACCESS_KEY` (see [bootstrap/README.md](bootstrap/README.md)
   for how to create them; CI should get its own token and key). The workflow
   also passes the Spaces key to the backend as `AWS_*`.

   If you use `postgres_trusted_ips`, also add a `POSTGRES_TRUSTED_IPS` secret
   holding the same JSON list, e.g. `["203.0.113.7"]`. Without it, CI plans
   (and applies) remove those IPs from the database firewall. It's a secret
   rather than a variable so it's masked in the logs. A plan that *changes*
   the list still prints the IPs, and plan comments are public.
2. **The `production` environment**, before the first merge. A workflow that
   names an environment that doesn't exist creates it *without* protection,
   and the apply would run unapproved. Under **Settings → Environments → New
   environment**, create `production`, tick **Required reviewers** and add
   yourself, and under **Deployment branches and tags** allow only `main`.
   Required reviewers need a public repo (or GitHub Enterprise).

Secrets with the same name set on the `production` environment override the
repository ones for apply jobs only. That allows read-only credentials in the
repository secrets (for PR plans) and full-access ones in `production`.

Pull requests from forks don't get secrets, so their plans fail. That's
expected: only the owner's branches get plans.

## Adding a project

1. Copy `projects/games/versions.tf` and `providers.tf` to `projects/<name>/`.
2. In `versions.tf`, change the backend `key` to `projects/<name>/terraform.tfstate`.
3. Copy the `terraform_remote_state` block and `locals` from
   `projects/games/main.tf`, setting `local.project = "<name>"`.
4. Add a `digitalocean_project` named `<name>` and assign the project's resources to it.
5. Run `terraform init`, then
   `terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_arm64`,
   and commit the resulting `.terraform.lock.hcl`.
6. Add the project to the tables above.

## Upgrading the provider

Bump the `version` constraint in every `versions.tf`, then in each root module:

```bash
terraform init -upgrade
terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_arm64
```
