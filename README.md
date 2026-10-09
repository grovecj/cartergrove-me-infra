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
    hub/           # the hub's landing page, served at "/"
  accounts/        # root module: auth.cartergrove.me sign-in service + its database
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
| `projects/accounts/` | `projects/accounts/terraform.tfstate` |

**Sharing values.** Projects read `shared/`'s outputs (`region`, `domain`,
`vpc_id`, `vpc_ip_range`, `postgres`) with a read-only `data "terraform_remote_state"
"shared"` block. `shared/outputs.tf` is the contract: projects should rely only
on what it exports.

## Shared resources

`shared/` owns everything more than one project uses:

- **DNS zone** `cartergrove.me`. The zone itself only. Each project creates its
  own subdomain records (`games`, `stats`, …). Records that were already in the
  zone (the apex `A` and `www`) are not managed by Terraform and are left as is.
- **Region `nyc1`** (`var.region`). App Platform's `nyc` region can only attach
  apps to VPCs in nyc1 (each App Platform region maps to one datacenter), and
  apps reach Postgres through the VPC, so the VPC and cluster must be there.
  Existing buckets (state, `games-downloads`) stay in nyc3: a bucket's region
  can't change in place, so moving one would replace it and delete its files.
- **VPC** `shared-nyc1`. Apps attach to it to reach Postgres privately.
- **Postgres cluster** `shared-postgres`: PostgreSQL 18, `db-s-1vcpu-1gb`
  (1 vCPU, 1 GiB RAM, 10 GiB disk), single node, **$15/month** at the time of
  writing (see DigitalOcean's pricing page). There's no standby node: a node failure
  means a few minutes of downtime while DO replaces it. Projects get a database
  and user with [`modules/project-database`](modules/README.md).
- **Database firewall.** Only the VPC's range, plus any IPs in
  `postgres_trusted_ips`, may connect. It lives in `shared/` because DO keeps
  one trusted-source list per cluster (see the module README).

The zone and the cluster have `prevent_destroy`: Terraform refuses any plan that
would delete them. To really delete one, remove that line first. (The
cluster's is switched off for its one-time move from nyc3 to nyc1, which
replaces it; switch it back on after that apply.)

### DNS: nameservers (one-time, done)

The registrar for `cartergrove.me` points at DigitalOcean's nameservers
`ns1.digitalocean.com`, `ns2.digitalocean.com` and `ns3.digitalocean.com`.
That's set in the registrar's control panel, not in Terraform. You'd only redo it
after transferring the domain. Check it with `nslookup -type=NS cartergrove.me`.

The zone already existed in DigitalOcean before Terraform, so `shared/main.tf`
*imports* it (an `import` block) instead of creating it. The first
`terraform plan` shows `1 to import`.

## Games hub (`projects/games/`)

`games.cartergrove.me` is **one** App Platform app, `games-hub`. App Platform
attaches a custom domain to exactly one app, so path-based hosting
(`/match3/`, `/<next-game>/`) means every game is a *component* of that app
rather than an app of its own.

- **Components.** `hub` serves the landing page at `/` from
  [`projects/games/hub/`](projects/games/hub/index.html) in this repo. Each
  game is a static site built from its own repo and branch, at `/<key>/`.
  Both are plain files with no build step.
- **Games map.** `var.games` in `projects/games/variables.tf` lists the games:

  ```hcl
  match3 = { repo = "grovecj/Match-3", branch = "web-build" }
  ```

  The app spec uses `dynamic` blocks to make one component and one routing rule
  per entry. Only the component whose branch changed gets rebuilt when a
  deploy runs.
- **Game APIs.** An entry may add an optional `api` (an `optional(...)`
  attribute in the variable's type), which gives the game a backend:

  ```hcl
  match3 = {
    repo   = "grovecj/Match-3"
    branch = "web-build"
    api    = { repo = "grovecj/match-3-api" } # also: branch (main), instance_size
  }
  ```

  - A **service** component `<key>-api`, built from the repo's `Dockerfile`
    on every push, listening on 8081, on the smallest instance.
  - A **route** `/<key>/api` → that service, so the API shares the game's
    origin (`https://games.cartergrove.me/match3/api`) and the web build
    needs no CORS. The route has `preserve_path_prefix = true`: the API
    sees `/match3/api/scores/top`, not `/scores/top`, and Spring's
    `server.servlet.context-path` is `/match3/api` locally too. One path
    everywhere, rather than a prefix that only exists in production. The
    health check (`/<key>/api/actuator/health`) reaches the container
    directly, so it includes the prefix as well.
  - A **database and user** `<key>` on the shared cluster, via
    `modules/project-database`. When any game has an API, the hub app is
    attached to the shared VPC and the API connects to the cluster's
    `private_host`, as `projects/accounts/` does. The database firewall
    already trusts the VPC, so nothing new is opened to the internet.
  - **Env vars:** `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`,
    `SPRING_DATASOURCE_PASSWORD` (`SECRET`), and for sign-in `AUTH_ISSUER`
    (the accounts project's `issuer` output, read from its state) and
    `AUTH_AUDIENCE` (the game key). The API checks tokens against the
    issuer's public keys, so it needs no auth secrets.

  Games without `api` get no service, route or database.
- **Domain and TLS.** A `CNAME` record `games` → the app's
  `*.ondigitalocean.app` hostname, in the shared zone. App Platform issues and
  renews the certificate itself once that record resolves, which can take a
  few minutes after the first apply.
- **Downloads.** Spaces bucket `games-downloads` (private, so it can't be
  listed) with a CDN in front of it. One prefix per game, e.g.
  `match3/Match3-Windows-latest.zip`. Uploads must set `public-read` on each
  file, or the CDN can't fetch it. The CDN caches files for an hour (`ttl`), so
  purge it after replacing a "latest" file (`doctl compute cdn flush <id> --files match3/*`).
- **Outputs** (`terraform output`) are what the game repos' CD workflows need:
  `app_id`, `app_url`, `game_urls`, `api_urls`, `downloads_bucket`,
  `downloads_bucket_endpoint`, `downloads_bucket_region`, `downloads_cdn_url`.

### One-time: GitHub access

App Platform pulls source through DigitalOcean's GitHub app, which is linked to
your DigitalOcean account in the control panel. The API token can't set it up.
Before the first apply: control panel → **Apps** → **Create App** → GitHub →
**Connect GitHub**, install the app for **Only select repositories**, and pick
`grovecj/cartergrove-me-infra` (for the landing page) plus each game's repo.
Once the repo picker lists them, cancel out of the wizard. To add a repo later,
use **Edit your GitHub permissions** on the same screen.

Without the link, the apply fails with `400 ... GitHub user not authenticated`.
Resources that don't depend on the app (bucket, CDN) may already have been
created by then. That's fine: the next apply only creates what's missing.

Each game's branch (e.g. Match-3's `web-build`) must exist before the apply
too, with a web build's `index.html` at its root.

### Adding a game

1. Add an entry to `var.games`: `<key> = { repo = "owner/name", branch = "..." }`.
   The key becomes the path (`/<key>/`), the component name and the downloads
   prefix: lowercase letters, digits and dashes.
2. Add a link to `/<key>/` in `projects/games/hub/index.html`, plus a link to
   its download on the CDN (`downloads_cdn_url`/`<key>/...`) if it has one.
3. Grant DigitalOcean's GitHub app access to the repo (see above), then `terraform apply`.

For a game with an `api`, also grant the GitHub app access to the API's repo,
and see "One-time: a game API's first apply" below. Keys of games with an API
can be at most 28 characters, so `<key>-api` fits App Platform's 32.

**Link with a trailing slash** (`/match3/`, not `/match3`). A Unity web build
loads `Build/...` relative to the page, and relative to `/match3` that's
`/Build/...`, which the hub answers with a 404. Ingress rules only match by
prefix, so a `/match3` → `/match3/` redirect can't be set up here (it would also
catch `/match3/` and loop). Making the bare URL work is up to the game's page,
e.g. a script in its web template that adds the missing slash.

### One-time: a game API's first apply

1. **Before merging:** `projects/accounts/` has been applied (its state holds
   the `issuer` output that `AUTH_ISSUER` comes from), and DigitalOcean's
   GitHub app can see the API's repo (e.g. `grovecj/match-3-api`). The hub
   only reads accounts' state while some game has an API.
2. **Apply.** It creates the database and user, then updates the hub app.
   The new deployment fails its health check, because Flyway can't create
   tables until the grant below exists, so the apply job fails at the app.
   That's expected and harmless: App Platform keeps the previous deployment
   live, so the hub and the games carry on as before.
3. **Database grant.** As `doadmin`, connected to the game's database (see
   [modules/README.md](modules/README.md#project-database)), with `<key>`
   replaced by the game's key:

   ```sql
   GRANT CREATE ON SCHEMA public TO "<key>";
   ```

   For Match-3 that's `GRANT CREATE ON SCHEMA public TO "match3";`. The
   double quotes keep the name exactly as written, which matters for keys
   with a dash (`block-drop`): unquoted, Postgres reads the dash as a minus.

4. **Deploy again.** Re-run the failed `apply (projects/games)` job and
   approve it. If its plan has no changes (the spec was saved even though
   the deployment failed), start a deployment yourself instead:
   `doctl apps create-deployment <app_id>`. Then check
   `curl https://games.cartergrove.me/<key>/api/actuator/health` says `UP`.

## Accounts (`projects/accounts/`)

`auth.cartergrove.me` runs the shared accounts service,
[grovecj/accounts](https://github.com/grovecj/accounts). Every
`*.cartergrove.me` project signs users in through it (with Google), and
validates the tokens it issues. Discovery is at
`https://auth.cartergrove.me/.well-known/openid-configuration`.

- **App.** App Platform app `accounts` with one service, `web`, built from
  the repo's `Dockerfile` on every push to `main`. It runs on the smallest
  instance (`var.instance_size`). New deployments only go live once
  `/actuator/health` answers.
- **Database.** Database and user `accounts` on the **shared** cluster, via
  `modules/project-database`. No cluster of its own. The app is attached to
  the shared VPC (the `vpc` block in its spec) and connects to the cluster's
  `private_host`. The database firewall already trusts the whole VPC, so
  nothing new is opened to the internet.
- **Env vars.** `SPRING_DATASOURCE_URL` (`jdbc:postgresql://<private_host>:<port>/accounts?sslmode=require`),
  `SPRING_DATASOURCE_USERNAME`, `AUTH_ISSUER` (`https://auth.cartergrove.me`),
  plus the `SECRET` ones: `SPRING_DATASOURCE_PASSWORD`, `GOOGLE_CLIENT_ID`,
  `GOOGLE_CLIENT_SECRET` and `AUTH_SIGNING_KEY_PEM`.
- **Google OAuth client.** Variables `google_client_id` and
  `google_client_secret`, both `sensitive`. CI fills them from the
  `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` secrets (see "One-time CI
  setup"). Locally, set `TF_VAR_google_client_id` / `TF_VAR_google_client_secret`.
  Creating the client is a manual step in Google Cloud: see
  [bootstrap/README.md](bootstrap/README.md#6-google-oauth-client-accounts).
- **JWT signing key.** `tls_private_key.jwt`, an ECDSA P-256 key (ES256)
  generated by Terraform and passed to the app as PKCS#8 PEM. It exists only in
  this project's state, in the private bucket.
- **Domain and TLS.** A `CNAME` record `auth` → the app's
  `*.ondigitalocean.app` hostname, as for the games hub.
- **Outputs:** `hostname`, `issuer`, `app_id`, `app_default_url`,
  `jwt_public_key_pem`.

**Keeping secrets out of logs.** The repo is public, and so are plan comments
and run logs. Terraform prints `(sensitive value)` for anything derived from a
sensitive value: the Google variables, the database password (a sensitive
module output), the private key, and every app env `value` (the provider marks
them sensitive). Never `terraform output` a sensitive value in CI, and never
upload a saved plan or state as an artifact.

### Rotating the signing key

```bash
cd projects/accounts
terraform apply -replace=tls_private_key.jwt
```

This makes a new key and redeploys the app with it. Every access token signed
with the old key stops validating at once. They live 15 minutes, so users are
at most asked to sign in or refresh again. In CI, there's no `-replace`: run it
locally (don't let it overlap a CI apply).

### One-time: before and after the first apply

1. **Google client and secrets** exist (bootstrap step 6, and "One-time CI
   setup" below). Without them the plan fails on purpose.
2. **GitHub access.** Add `grovecj/accounts` to DigitalOcean's GitHub app
   (see "One-time: GitHub access" above).
3. **Apply.** CI applies `shared/` first. The first time, that moves the VPC
   and the cluster from nyc3 to nyc1, which **replaces** both (the cluster
   comes back empty, with new hostnames). If deleting the old VPC fails
   because it still has members, wait a few minutes for DO to release the
   old cluster and re-run the job. Then `projects/accounts/` is applied. Its
   first deployment fails the health check, because Flyway can't create
   tables until the grant below exists. That's expected: the database and
   user already exist, but the apply fails at the app. Terraform marks the
   app *tainted* and skips what depends on it (the `auth` CNAME, the DO
   Project). After this, turn `prevent_destroy` on the cluster back on
   (`shared/main.tf`).
4. **Database grant.** As `doadmin`, connected to the `accounts` database (see
   [modules/README.md](modules/README.md#project-database)):

   ```sql
   GRANT CREATE ON SCHEMA public TO accounts;
   ```

5. **Re-run the accounts apply** (the failed `apply (projects/accounts)` job →
   **Re-run jobs**, and approve it again). Its plan replaces the tainted app,
   whose deployment now succeeds, and creates the CNAME and Project. A
   redeploy from the control panel isn't enough: it would fix the app but
   leave those two uncreated. Then check
   `curl https://auth.cartergrove.me/.well-known/openid-configuration` shows
   `"issuer":"https://auth.cartergrove.me"`. The discovery endpoint arrives
   with grovecj/accounts#3; until then, `/actuator/health` should say `UP`.

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

   For `projects/accounts/`, add `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`
   (the production OAuth client, from bootstrap step 6) as repository secrets
   **and** as `production` environment secrets. The workflows pass them as
   `TF_VAR_google_client_id` / `TF_VAR_google_client_secret`. Without them,
   the accounts plan fails with "google_client_id is empty".
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
