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

Apply `shared/` before any project that reads its outputs. CI for plan/apply is
tracked in grovecj/cartergrove-me-infra#5.

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
