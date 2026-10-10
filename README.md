# cartergrove-me-infra

Terraform for the DigitalOcean infrastructure behind every `*.cartergrove.me`
project (games.cartergrove.me, stats.cartergrove.me, ...), and for the Grafana
Cloud stack that monitors it. Keeping it in one repo lets projects share
resources, like one managed Postgres cluster, without stepping on each other.

## Layout

```
shared/            # root module: DNS zone, VPC, shared Postgres cluster, ...
monitoring/        # root module: Grafana Cloud (telemetry credentials, Synthetic Monitoring, dashboards)
projects/
  games/           # root module: games.cartergrove.me hub (one app, one path per game)
    hub/           # the hub's landing page, served at "/"
  accounts/        # root module: auth.cartergrove.me sign-in service + its database
  beach/           # root module: beach.cartergrove.me live cam page
  minecraft/       # root module: minecraft.cartergrove.me server (a Droplet)
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
| `monitoring/` | `monitoring/terraform.tfstate` |
| `projects/games/` | `projects/games/terraform.tfstate` |
| `projects/accounts/` | `projects/accounts/terraform.tfstate` |
| `projects/beach/` | `projects/beach/terraform.tfstate` |
| `projects/minecraft/` | `projects/minecraft/terraform.tfstate` |

**Sharing values.** Projects read `shared/`'s outputs (`region`, `domain`,
`vpc_id`, `vpc_ip_range`, `postgres`) with a read-only `data "terraform_remote_state"
"shared"` block. `projects/accounts/` and `projects/games/` read `monitoring/`'s outputs
(`otlp_endpoint`, `otlp_authorization`, and the `synthetic_monitoring_*` pair
their uptime checks are made with) the same way, wrapping the tokens in
`sensitive(...)`: an output's `sensitive` marking doesn't survive the trip
through remote state (see "Monitoring"). `shared/outputs.tf` is the contract: projects should rely only
on what it exports. `monitoring/outputs.tf` is the same kind of contract
(see "Monitoring" below); `monitoring/` itself reads nothing from `shared/`.

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
would delete them. To really delete one, remove that line first.

### DNS: nameservers (one-time, done)

The registrar for `cartergrove.me` points at DigitalOcean's nameservers
`ns1.digitalocean.com`, `ns2.digitalocean.com` and `ns3.digitalocean.com`.
That's set in the registrar's control panel, not in Terraform. You'd only redo it
after transferring the domain. Check it with `nslookup -type=NS cartergrove.me`.

The zone already existed in DigitalOcean before Terraform, so `shared/main.tf`
*imports* it (an `import` block) instead of creating it. The first
`terraform plan` shows `1 to import`.

## Monitoring (`monitoring/`)

Health monitoring for the services (tracking issue:
[grovecj/Match-3#92](https://github.com/grovecj/Match-3/issues/92)) runs on
[Grafana Cloud](https://grafana.com/products/cloud/)'s free tier. This root
module makes the credentials services send telemetry with, switches on
Synthetic Monitoring so projects can declare uptime checks, and loads the
dashboard. Alerts get added here later.

- **Push, not scrape.** The usual Prometheus setup *pulls*: a collector
  scrapes a `/metrics` endpoint on every service. App Platform has nowhere to
  run a collector, and we don't want `/actuator/prometheus` on a public
  route. So each service *pushes* over OTLP (the OpenTelemetry Protocol:
  HTTP POSTs of metrics, logs or traces) to the stack's OTLP gateway,
  `https://otlp-gateway-<zone>.grafana.net/otlp`.
- **One stack, read not created.** The free tier includes one stack, made at
  sign-up. `data "grafana_cloud_stack"` looks it up by its slug
  (`var.grafana_stack_slug`); Terraform can't change or delete it.
- **Separate credentials, on purpose.** Each is as narrow as its job allows.

  | Credential | Can | Lives |
  | --- | --- | --- |
  | Terraform's token (`GRAFANA_CLOUD_ACCESS_POLICY_TOKEN`) | manage access policies, tokens and the stack's service accounts | your shell, CI secrets. Made by hand: [bootstrap step 7](bootstrap/README.md#7-grafana-cloud-account-and-terraform-token-monitoring) |
  | Services' token (`grafana_cloud_access_policy_token.services_write`) | only `metrics:write`, `logs:write`, `traces:write`, only on this stack | this root's state, and each service's `GRAFANA_OTLP_AUTHORIZATION` env var. Made by Terraform |
  | Probes' token (`grafana_cloud_access_policy_token.synthetic_monitoring`) | the same writes plus `stacks:read`, only on this stack | this root's state, and Grafana's Synthetic Monitoring backend, which writes check results with it. Made by Terraform |
  | Synthetic Monitoring access token (`grafana_synthetic_monitoring_installation.main`) | create, change and delete uptime checks | this root's state, and the projects' grafana provider (read from state at plan time, never given to a service). Made by Grafana when Terraform installs Synthetic Monitoring |
  | Terraform's service account token (`grafana_cloud_stack_service_account_token.terraform`) | sign in to the stack's Grafana as an Admin, used for folders and dashboards | this root's state only. Made by Terraform |

  A service is the likelier place for a leak (logs, a debug endpoint, a
  dependency). Its token can add junk data and nothing else: it can't read
  what was sent, open Grafana, or make more tokens.
- **Synthetic Monitoring is installed here, used elsewhere.** Pushed metrics
  are *white-box* monitoring: a service reporting on itself, which stops when
  it dies. Synthetic Monitoring is the *black-box* half: Grafana's probe
  servers request our public URLs from outside and record whether that
  worked. `grafana_synthetic_monitoring_installation` switches it on for the
  stack; the checks are declared by the project that owns each URL, which
  keeps the dependency one-way (projects read `monitoring/`, never the
  reverse).
- **Outputs**, the contract with the projects:
  - `otlp_endpoint`: the gateway's base URL. Clients add `/v1/metrics`,
    `/v1/logs` or `/v1/traces`.
  - `otlp_authorization` (sensitive): the whole `Authorization` header value,
    `Basic base64(<stack id>:<token>)`. base64 is an encoding, not
    encryption, so treat it exactly like the token. **`sensitive` stops at
    this root's edge.** Read through `terraform_remote_state`, the value
    arrives as a plain string that a plan prints in full, and plan comments
    here are public. A project that reads it must wrap it in `sensitive(...)`
    on the spot.
  - `prometheus`: the metrics query URL and user id. Not secret; used for the
    read check below.
  - `synthetic_monitoring_url` and `synthetic_monitoring_access_token`
    (sensitive): what a project's `provider "grafana"` needs to manage
    uptime checks (`sm_url`, `sm_access_token`). The same warning applies to
    the token: wrap it in `sensitive(...)` where it's read.

  Projects pass the first two to their services as `GRAFANA_OTLP_ENDPOINT`
  and `GRAFANA_OTLP_AUTHORIZATION` (`SECRET`), plus
  `DEPLOYMENT_ENVIRONMENT=production`, which the services attach to
  everything they send (it's `local` when unset).

### Free-tier budget

What everything here has to fit in, as of October 2026 (they move: check
[grafana.com/pricing](https://grafana.com/pricing/) before relying on one):

| What | Limit |
| --- | --- |
| Metrics | 10,000 active series, across **all** services |
| Logs, traces | 50 GB ingested a month, each |
| Retention | 14 days, for metrics, logs and traces |
| Synthetic (uptime) checks | 100,000 API check runs a month (plus 10,000 browser ones) |
| Users | 3 active a month |

Two of these shape the design. An *active series* is one metric name with one
combination of label values, so a label with unbounded values (a raw URL, a
user id) can eat the 10k by itself. And 100k check runs a month is about one
check a minute for two targets (a month has ~43,800 minutes), so checks have
to be fewer or slower than that.

### Uptime checks

Five HTTP checks, each a plain public `GET` every 5 minutes from one probe
location (Ohio). No check signs in or carries a credential.

| Check (`job`) | `service` | URL | Passes when | Declared in |
| --- | --- | --- | --- | --- |
| `match3-api health` | `match3-api` | `https://games.cartergrove.me/match3/api/actuator/health` | 200 and status `UP` | `projects/games/` |
| `match3-api database` | `match3-api` | `https://games.cartergrove.me/match3/api/scores/top?limit=1` | 200 and a JSON array | `projects/games/` |
| `match3 web` | `match3-web` | `https://games.cartergrove.me/match3/` | 200 | `projects/games/` |
| `accounts discovery` | `accounts` | `https://auth.cartergrove.me/.well-known/openid-configuration` | 200 and `issuer` is `https://auth.cartergrove.me` | `projects/accounts/` |
| `accounts signing keys` | `accounts` | `https://auth.cartergrove.me/oauth2/jwks` | 200 and at least one key | `projects/accounts/` |

- **Two checks per API, because "up" has two meanings.** `health` is
  *liveness*: the process is running and answering. It's the path App
  Platform's own health check uses, and it deliberately doesn't look at the
  database, because a health check that fails on a database blip gets a
  healthy container restarted. `database` is the other question, "can it do
  its job?": a real read of the leaderboard, which fails when the API can't
  reach Postgres. (The achievements list wouldn't do: it's served from the
  API's configuration without touching the database.)
- **Declared where the URL is.** The game checks are generated from
  `var.games` in `projects/games/`, so a new game is checked from its first
  apply: one check for its web build, two more if it has an `api`. Both
  projects call [`modules/uptime-checks`](modules/README.md#uptime-checks),
  which holds the settings they share (probe, interval, timeout).
- **What a check records.** Success, duration and status code, as metrics
  labelled `job`, `instance` (the URL) and `probe`, and because the URLs are
  HTTPS, when the TLS certificate expires. The `service` label is kept on
  one series per check, `sm_check_info` (as `label_service`), to be joined
  to the others on `job` and `instance`. In Grafana: **Testing & synthetics
  → Synthetics → Checks**.
- **Alerts are separate.** A failing check shows red in Grafana and tells
  nobody. That's the alerting issue.

**Budget.** The free tier allows 100,000 check runs a month. One check, from
one location, every 5 minutes, is 12 runs an hour: 8,928 in a 31-day month.

| Checks | Runs in a 31-day month | Of the allowance |
| --- | --- | --- |
| 5 (today) | 44,640 | 45% |
| 8 (a second game with an API) | 71,424 | 71% |
| 11 (a third) | 98,208 | 98% |

A second probe location doubles every row, so 5 checks from two locations is
89,280: it fits today and stops fitting with the next game. Past three games
with APIs, raise `frequency_minutes` to 10 in both projects' `module "uptime"`
blocks, which halves everything. Actual usage is on the stack's billing and
usage dashboard in Grafana.

### The Services dashboard

One dashboard, **Services**, in the `cartergrove.me` folder: Grafana →
**Dashboards**, or `terraform output services_dashboard_url` in `monitoring/`.
It answers "are the services OK?" from top to bottom:

| Row | Panels | Answers |
| --- | --- | --- |
| From outside | every uptime check's result, share passed, duration, days left on the certificate | Can a player reach it? |
| Traffic and errors | requests per second by route; 5xx and 4xx per second | Is it being used, and is it failing? |
| Latency | p50 / p95 / p99, and p95 by route | Is it slow, and where? |
| Saturation | database connections against the pool's 3, JVM heap against its maximum, CPU, garbage collection pauses | How close to full is it? |
| Restarts | process uptime | Did it deploy or crash? |

- **The four golden signals** (traffic, errors, latency, saturation) decide
  what's on it. A panel that isn't one of those, or the outside view, belongs
  on a different dashboard. The first three are what a player feels; the
  fourth is what goes wrong next.
- **One service at a time.** The **Service** picker at the top lists whatever
  has reported from production, so a new service appears by itself. The top
  row ignores it: a web build has checks but sends no metrics.
- **Restarts are marked on every panel** (the blue lines, from the
  **Restarts** annotation): a spike that lines up with one is a deploy, not a
  mystery.
- **It adds no series.** A dashboard only reads. Every query groups by labels
  the services already keep to short lists (`uri` is the route, `status` the
  code), so it can't grow the bill.
- **Rates are over 5 minutes.** `rate(...[5m])` turns a counter into a
  per-second speed. The services push once a minute, and a rate needs at
  least two points, so shorter windows come up empty.
- **Percentiles are estimates.** The services count requests into 8 duration
  buckets (10 ms to 2.5 s); `histogram_quantile(0.95, ...)` works out "95% of
  requests were faster than this" from the counts, assuming requests are
  spread evenly inside a bucket.

How it gets there: `monitoring/dashboards/services.json` is the dashboard,
in the format Grafana exports and imports. `grafana_dashboard` uploads it.
The stack's Grafana has its own API and login, apart from grafana.com's, so
Terraform makes itself a *service account* there (role Admin) and a second
`provider "grafana"` block (`grafana.stack`) signs in with its token.

#### Changing the dashboard

The file is the source of truth: **anything saved in the UI is overwritten by
the next apply.** So:

1. Open the dashboard and edit it in Grafana (**Edit**), where you can see
   what a query returns. Don't worry about saving.
2. **Export → Export as JSON** (turn *Export for sharing externally* off, so
   the data source stays as it is), and put the result in
   `monitoring/dashboards/services.json`.
3. Commit, open a pull request, read the diff, merge. The apply uploads it.

The first export will reorder and add fields compared with the file as it
was first written by hand; after that, diffs are only what changed.

The trade-off: the UI is much the nicer editor, but a dashboard that only
lives there has no history, no review, and is gone if someone deletes it.
In the repo it has all three, at the price of the export step. For a
throwaway experiment, make a new dashboard outside the `cartergrove.me`
folder; Terraform leaves those alone.

To check that Terraform really owns it: delete the dashboard in the UI, run
`terraform apply` in `monitoring/` (the plan is 1 to add), and it's back at
the same URL.

### One-time: first apply

1. **Account, token, secrets** exist ([bootstrap step 7](bootstrap/README.md#7-grafana-cloud-account-and-terraform-token-monitoring)).
   Without them the plan fails on purpose (`grafana_stack_slug is empty`), or
   with an authentication error from Grafana.
2. **Apply** `monitoring/`, by merging (it's applied after `shared/`, before
   the projects) or locally. The plan is 5 to add: the services' policy and
   token, the probes' policy and token, and the Synthetic Monitoring
   installation. (The dashboard came later: its apply is 4 to add, and
   fails with a 403 until Terraform's token has the
   `stack-service-accounts:write` scope from bootstrap step 7.)
3. **Check the token can write but not read.** Locally, in `monitoring/`
   (bash, with `jq`; don't run this in CI, it handles the secret):

   ```bash
   # Write: send one made-up data point. Expect 200.
   curl -s -o /dev/null -w '%{http_code}\n' -X POST "$(terraform output -raw otlp_endpoint)/v1/metrics" \
     -H "Authorization: $(terraform output -raw otlp_authorization)" \
     -H 'Content-Type: application/json' \
     -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"curl-test"}}]},"scopeMetrics":[{"metrics":[{"name":"curl_test","gauge":{"dataPoints":[{"asInt":"1","timeUnixNano":"'"$(date +%s)"'000000000"}]}}]}]}]}'

   # Read: query metrics with the same token. Expect 401 or 403.
   token=$(terraform output -raw otlp_authorization | cut -d' ' -f2 | base64 -d | cut -d: -f2)
   curl -s -o /dev/null -w '%{http_code}\n' -u "$(terraform output -json prometheus | jq -r .user_id):$token" \
     "$(terraform output -json prometheus | jq -r .url)/api/prom/api/v1/query?query=up"
   ```

   The `curl_test` series shows up in the stack's **Explore** (pick the
   Prometheus data source) and ages out by itself.
4. **Only then** can `projects/accounts/` and `projects/games/` plan: they
   read these outputs, and fail with `Unable to find remote state` until
   `monitoring/terraform.tfstate` exists. Their next apply adds the three env
   vars (`GRAFANA_OTLP_ENDPOINT`, `GRAFANA_OTLP_AUTHORIZATION`,
   `DEPLOYMENT_ENVIRONMENT`) and redeploys the services.

### Rotating the services' token

```bash
cd monitoring
terraform apply -replace=grafana_cloud_access_policy_token.services_write
```

Then apply `projects/accounts` and `projects/games`, which redeploys the
services with the new value. The old token stops working as soon as it's
replaced, so until that redeploy the services' pushes are refused (they log
it and carry on; only telemetry is lost). As with the signing key, there's no
`-replace` in CI: run it locally, and don't let it overlap a CI apply.

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
    issuer's public keys, so it needs no auth secrets. For monitoring,
    `GRAFANA_OTLP_ENDPOINT` and `GRAFANA_OTLP_AUTHORIZATION` (`SECRET`),
    from `monitoring/`'s state, and `DEPLOYMENT_ENVIRONMENT` (`production`).

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
   prefix: 2-28 lowercase letters, digits and dashes.
2. Add a link to `/<key>/` in `projects/games/hub/index.html`, plus a link to
   its download on the CDN (`downloads_cdn_url`/`<key>/...`) if it has one.
3. Grant DigitalOcean's GitHub app access to the repo (see above), then `terraform apply`.

Uptime checks come with it: one for the web build, two more for an `api`.
They count against a monthly allowance, so look at the budget table under
"Uptime checks" first.

For a game with an `api`, also grant the GitHub app access to the API's repo,
and see "One-time: a game API's first apply" below. Keys stop at 28
characters so that `<key>-api` and `<key>-web` fit in 32: App Platform's limit
for a component name, and Grafana's for the `service` label on a check.

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
  `GOOGLE_CLIENT_SECRET` and `AUTH_SIGNING_KEY_PEM`. For monitoring,
  `GRAFANA_OTLP_ENDPOINT` and `GRAFANA_OTLP_AUTHORIZATION` (`SECRET`), read
  from `monitoring/`'s state like `shared/`'s outputs, and
  `DEPLOYMENT_ENVIRONMENT` (`production`).
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
   Project). (`prevent_destroy` on the cluster was off for this move and is
   back on now.)
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

## Beach cams (`projects/beach/`)

`beach.cartergrove.me` serves a page of live cams from Schooners in Panama
City Beach, kept in the private repo
[grovecj/schooners-cams](https://github.com/grovecj/schooners-cams).

- **App.** App Platform app `beach-site` with one static site, `web`, served
  from the repo root (`var.repo`, branch `var.branch`) with no build step.
  Pushing to `main` redeploys it.
- **Domain and TLS.** A `CNAME` record `beach` → the app's
  `*.ondigitalocean.app` hostname, as for the games hub.
- **Outputs:** `hostname`, `app_id`, `app_url`, `app_default_url`.

**Before the first apply**, add `grovecj/schooners-cams` to DigitalOcean's
GitHub app (see "One-time: GitHub access" above). The repo is private, so
App Platform can't see it otherwise, and the apply fails with
`GitHub user not authenticated`.

## Minecraft (`projects/minecraft/`)

`minecraft.cartergrove.me` is a Paper Minecraft server for Java and Bedrock
players, with a BlueMap web map at `https://minecraft.cartergrove.me`. What
runs on the machine (`docker-compose.yml`, the `Caddyfile`, the plugin list)
lives in [grovecj/minecraft-server](https://github.com/grovecj/minecraft-server).
This project only builds the machine. It was moved here from that repo's
`terraform/` folder, which kept its state on one laptop.

- **Droplet** `minecraft-server`: Ubuntu 24.04, `s-2vcpu-4gb` (`var.size`),
  **$24/month** at the time of writing. It's the one project on a Droplet
  instead of App Platform, which only routes HTTP: Minecraft needs its own
  ports. It sits in the region's default VPC, not the shared one, because it
  has SSH open to the internet and needs no database.
- **First boot.** [`cloud-init.yml`](projects/minecraft/cloud-init.yml)
  installs Docker, adds 2 GB of swap and a daily world backup (kept 7 days,
  on the same disk), clones `var.repo` to `/opt/minecraft` and runs
  `docker compose up -d`. The repo must be public, since the clone has no
  credentials. cloud-init runs **only** on a Droplet's first boot, so editing
  the file changes nothing on a running server (`ignore_changes = [user_data]`
  keeps Terraform from rebuilding it). Later config changes go through the
  server repo's own Deploy workflow.
- **Firewall** `minecraft-firewall`: inbound SSH (22), Java (25565), Bedrock
  (19132/udp) and HTTP/HTTPS (80, 443) from anywhere; everything outbound.
- **DNS.** An `A` record `minecraft` → the Droplet's IP. Caddy on the Droplet
  gets the TLS certificate itself once the record resolves.
- **Outputs:** `hostname`, `bluemap_url`, `droplet_id`, `droplet_ip`,
  `ssh_command`.

The Droplet has `prevent_destroy`: the world is on its disk
(`/opt/minecraft/data`), so Terraform refuses any plan that would delete it.
Resizing (`var.size`) is done in place, with a short power-off. Changing the
image or region replaces the Droplet, so back the world up first.

### One-time: the first apply

The old Droplet is gone, but its firewall and `A` record were left behind.
`main.tf` *imports* both (`import` blocks, as `shared/` does for the DNS zone)
instead of making duplicates, so the first plan reads
`2 to import, 2 to add, 2 to change`: the Droplet and the DO Project are new,
and the firewall and the record are pointed at the new Droplet.

1. **SSH key.** The account has a key named `1PASSWORD-DigitalOcean`
   (`var.ssh_key_name`). Check with `doctl compute ssh-key list`.
2. **Apply.** The Droplet is up within a minute. cloud-init then takes a few
   more to install Docker and start the server; follow it with
   `ssh root@<droplet_ip> cloud-init status --wait`.
3. **Server repo secret.** In grovecj/minecraft-server, set the `SERVER_HOST`
   Actions secret to `minecraft.cartergrove.me` (it held the old Droplet's
   IP), so its Deploy workflow reaches the new one.

The new Droplet starts with a **fresh world**. To bring an old one back, stop
the server (`docker compose down` in `/opt/minecraft`), copy the world into
`/opt/minecraft/data/world`, and start it again.

## Conventions

- **Naming:** resources are prefixed with their project: `games-downloads`,
  `games-hub`.
- **Tags:** every taggable resource gets `project:<name>` (`local.tags`).
- **DO Projects:** each project's resources are assigned to a DigitalOcean
  Project of the same name, so the control panel groups them. `shared/`'s
  resources go in the hand-made `cartergrove.me` project, which Terraform
  only reads (a `data` source) and doesn't manage.
- **Versions:** Terraform `~> 1.14` and provider `digitalocean/digitalocean`
  `~> 2.102` (`monitoring/` uses `grafana/grafana` `~> 4.49` instead, and
  `projects/accounts/` and `projects/games/` use both). The
  exact provider build is pinned by each root module's committed
  `.terraform.lock.hcl` (hashes for Windows, Linux and macOS arm64).
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

Apply order: `shared/`, then `monitoring/`, then the projects, because
projects read the outputs of the first two.

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
deploy**. `shared` is applied first, as its own job, then `monitoring`,
because projects read the outputs of both. The projects' applies only start
after those succeed (or when they have no changes). Only approve after
reading the plan.

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

   For `monitoring/`, add the `GRAFANA_CLOUD_ACCESS_POLICY_TOKEN` secret
   (repository **and** `production`) and the `GRAFANA_STACK_SLUG` repository
   *variable*, from bootstrap step 7. The provider reads the token from the
   environment; the slug is passed as `TF_VAR_grafana_stack_slug`.
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
