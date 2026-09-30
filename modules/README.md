# Modules

Reusable building blocks called from root modules (`shared/`, `projects/*`).
A module has no backend and no provider configuration of its own: it uses the
caller's provider, and its resources are stored in the caller's state.

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
