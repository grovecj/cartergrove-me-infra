# Modules

Reusable building blocks called from root modules (`shared/`, `projects/*`).
A module has no backend and no provider configuration of its own: it uses the
caller's provider, and its resources are stored in the caller's state.

## `uptime-checks/`

Outside-in HTTP checks, run by Grafana Cloud Synthetic Monitoring: every few
minutes a probe requests each URL and records whether it answered properly
and how fast. A project calls this for the URLs it owns.

```hcl
module "uptime" {
  source = "../../modules/uptime-checks"

  checks = {
    "accounts discovery" = {                       # the check's `job` label
      url             = "${local.issuer}/.well-known/openid-configuration"
      service         = local.project              # the `service` label
      body_must_match = ["\"issuer\""]             # optional: regexes, all must match
    }
  }
}
```

A check passes when the URL answers 200 over TLS and the body matches every
regular expression given. It's a plain `GET` with no credentials, so only
point it at public, read-only URLs.

| Variable | Default | |
| --- | --- | --- |
| `checks` | (required) | map of name => `{ url, service, body_must_match }` |
| `probe` | `"Ohio"` | the one probe location that runs them |
| `frequency_minutes` | `5` | every check, from that location |
| `timeout_seconds` | `10` | 1 to 180 |

| Output | |
| --- | --- |
| `max_runs_per_month` | runs these checks use in a 31-day month, for the budget in the top-level README |

**The caller configures the provider.** The module uses the caller's
`grafana` provider, which must be set up for Synthetic Monitoring with
`monitoring/`'s outputs (see `projects/accounts/providers.tf`):

```hcl
provider "grafana" {
  sm_url          = data.terraform_remote_state.monitoring.outputs.synthetic_monitoring_url
  sm_access_token = sensitive(data.terraform_remote_state.monitoring.outputs.synthetic_monitoring_access_token)
}
```

**Regular expressions are written twice-escaped.** They're Go (RE2) syntax,
inside a Terraform string, so a regex backslash is `\\` and a quote is
`\"`: the regex `"status"\s*:\s*"UP"` is written
`"\"status\"\\s*:\\s*\"UP\""`.

**A wrong probe name fails the plan** with the list of valid ones.

## `project-database/`

A database + user for one project on the shared Postgres cluster. Projects
never create clusters; they call this instead.

```hcl
module "db" {
  source  = "../../modules/project-database"
  name    = local.project                                   # database and user name
  cluster = data.terraform_remote_state.shared.outputs.postgres
}

# e.g. in an App Platform env var (type = "SECRET"): module.db.private_uri
```

| Output | |
| --- | --- |
| `database`, `user` | names (both equal `name`) |
| `password` | sensitive |
| `private_uri` | sensitive; `postgresql://…` via the VPC, for apps |
| `uri` | sensitive; via the public host, only from `postgres_trusted_ips` |

**One-time grant after the first apply.** Since PostgreSQL 15, only a
database's owner may create tables in its `public` schema. DO makes `doadmin`
the owner, so the project's user can connect but not create tables (or run
migrations) until `doadmin` grants it:

1. Put your IP in `shared/`'s `postgres_trusted_ips` and apply `shared/`.
2. Copy the `doadmin` connection string from the control panel (Databases →
   `shared-postgres` → Connection details), with the database set to the
   project's (e.g. `games`). Schemas are per database, so connecting to
   `defaultdb` would grant on the wrong one.
3. `psql "<that connection string>" -c "GRANT CREATE ON SCHEMA public TO games;"`

Terraform could do this with the `postgresql` provider. That needs network
access to the cluster from wherever Terraform runs, and the admin password in
the project's config, which is too much machinery for one line of SQL run once.

**Network access.** The module doesn't touch the cluster's firewall. DigitalOcean
keeps one trusted-source list per cluster and `digitalocean_database_firewall`
overwrites the whole list, so two projects each adding "their" rule would undo
each other on every apply. Instead `shared/` owns the firewall and trusts the
whole shared VPC. A project gets access by attaching its App Platform app to that
VPC (`data.terraform_remote_state.shared.outputs.vpc_id`).

**Isolation between projects.** Each project has its own user and password.
Tables a user creates belong to that user, and other users can't read them.
Postgres does still let any user *connect* to any database on the cluster by
default. For a single-owner hobby setup that's acceptable. To lock it down, run
`REVOKE CONNECT ON DATABASE <name> FROM PUBLIC;` as `doadmin`.
