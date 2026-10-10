# Monitoring for every *.cartergrove.me service, on Grafana Cloud's free tier.
# This root module finds the stack, makes the credentials services push
# telemetry with, switches on Synthetic Monitoring (uptime checks) for the
# projects to declare their checks in, and loads the dashboards. Alerts are
# added here by a later issue.
#
# How telemetry gets to Grafana: services *push* it over OTLP (the
# OpenTelemetry Protocol, plain HTTP POSTs of metrics, logs or traces) to the
# stack's OTLP gateway. The usual alternative is *pull*: a collector scrapes a
# /metrics endpoint on each service. App Platform has nowhere to run a
# collector, and we don't want a metrics endpoint on a public route, so push
# it is.

# A "stack" is one Grafana Cloud environment: a Grafana instance plus its own
# metrics, logs and traces databases. The free tier includes exactly one,
# created at sign-up, so we look it up (a `data` source) rather than create
# one (a `resource`). Terraform reads it and can never change or delete it.
data "grafana_cloud_stack" "main" {
  slug = var.grafana_stack_slug
}

locals {
  project = "monitoring"

  # Access policies live in a region, the one the stack is in ("prod-us-east-0").
  region = data.grafana_cloud_stack.main.region_slug
}

# --- Write credentials for services ------------------------------------------

# An access policy says what its tokens may do (scopes) and where (realm).
# This one can only *write* telemetry, and only to this stack. A service that
# leaks its token gives away the ability to send us junk data. It can't read
# what other services sent, open dashboards or change anything in Grafana.
resource "grafana_cloud_access_policy" "services_write" {
  region       = local.region
  name         = "services-telemetry-write"
  display_name = "Services: write telemetry (Terraform)"

  scopes = ["metrics:write", "logs:write", "traces:write"]

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.main.id
  }
}

# A token is a credential issued under a policy. One token is shared by all
# services: they're all ours, and it can only write. It never expires; to
# rotate it (say, after a leak):
#   terraform apply -replace=grafana_cloud_access_policy_token.services_write
# then apply the projects, which redeploys the services with the new value.
# The token itself exists only in this root's state, in the private bucket.
resource "grafana_cloud_access_policy_token" "services_write" {
  region           = local.region
  access_policy_id = grafana_cloud_access_policy.services_write.policy_id
  name             = "services-telemetry-write"
  display_name     = "Services: write telemetry (Terraform)"
}

# --- Synthetic Monitoring (uptime checks) -------------------------------------

# Metrics a service pushes are *white-box* monitoring: the service reports on
# itself. They stop when it dies, and "no data" looks the same as "nobody is
# playing". Synthetic Monitoring is the *black-box* half: Grafana's own probe
# servers request our public URLs every few minutes, the way a player's
# browser would, and record whether that worked and how long it took. Only
# that can say "down".
#
# This root only installs it. The checks themselves are declared by the
# project that owns each URL (modules/uptime-checks), so a URL and its check
# live side by side and a new game gets its checks in the same apply.

# The probes write their results (metrics and logs) into our stack, and need a
# credential for it, like the services do. It gets its own policy instead of
# sharing services_write: Grafana asks for `stacks:read` as well, and this
# token is held by Grafana's Synthetic Monitoring backend, not by our
# services, so either can be rotated without touching the other.
resource "grafana_cloud_access_policy" "synthetic_monitoring" {
  region       = local.region
  name         = "synthetic-monitoring-publish"
  display_name = "Synthetic Monitoring: publish check results (Terraform)"

  scopes = ["metrics:write", "logs:write", "traces:write", "stacks:read"]

  realm {
    type       = "stack"
    identifier = data.grafana_cloud_stack.main.id
  }
}

resource "grafana_cloud_access_policy_token" "synthetic_monitoring" {
  region           = local.region
  access_policy_id = grafana_cloud_access_policy.synthetic_monitoring.policy_id
  name             = "synthetic-monitoring-publish"
  display_name     = "Synthetic Monitoring: publish check results (Terraform)"
}

# "Installing" registers the stack with the Synthetic Monitoring API and hands
# it the token above. It's safe on a stack where it's already installed (the
# Grafana UI can do it too). What comes back is a third kind of credential:
# an access token for the Synthetic Monitoring API itself, which is what
# creates and deletes checks. See outputs.tf for where that goes.
resource "grafana_synthetic_monitoring_installation" "main" {
  stack_id              = data.grafana_cloud_stack.main.id
  metrics_publisher_key = grafana_cloud_access_policy_token.synthetic_monitoring.token
}

# --- Inside the stack: dashboards ---------------------------------------------

# Everything above is the *account* side of Grafana Cloud, done with
# Terraform's Cloud token. What's inside the stack's Grafana (folders,
# dashboards, later alert rules) is a different API with its own login: the
# Cloud token doesn't open it. A *service account* is that login: a user for a
# program instead of a person. It doesn't count towards the free tier's 3
# users. See providers.tf for how its token is used.
#
# Admin, because Editor isn't enough for a folder's first moments. An
# Editor's right to read a folder is granted folder by folder, and the grant
# for a new one takes a moment to arrive: Grafana let this account create the
# folder, then refused to let it read it straight back (403, "Permissions
# needed: folders:read"), which is what the provider does after every create.
# An Admin may read every folder, so there's nothing to wait for. It's also
# what the alert rules' contact points will need. It does make the token
# below worth more to a thief (an Admin can change anything in this Grafana),
# so it stays where it is: only in this root's state, in the private bucket.
#
# Changing `role` replaces the account, and with it the token. See the token
# for why that takes two applies.
resource "grafana_cloud_stack_service_account" "terraform" {
  stack_slug = data.grafana_cloud_stack.main.slug
  name       = "terraform"
  role       = "Admin"
}

# Never expires, like the services' token. Nothing else holds it: it exists
# only in this root's state.
#
# Replacing it takes two applies, locally. The grafana.stack provider signs
# in with this token, and while a new one is only planned its value is
# unknown, so Terraform can't plan the folder or dashboard in the same run
# ("the Grafana client is required for this resource"). -target plans the
# token alone:
#   terraform apply -target=grafana_cloud_stack_service_account_token.terraform -replace=grafana_cloud_stack_service_account_token.terraform
#   terraform apply
resource "grafana_cloud_stack_service_account_token" "terraform" {
  stack_slug         = data.grafana_cloud_stack.main.slug
  service_account_id = grafana_cloud_stack_service_account.terraform.id
  name               = "terraform"
}

# One folder for everything Terraform puts in Grafana, so it's obvious which
# dashboards are code (edits in the UI get overwritten) and which were made by
# hand to try something out.
resource "grafana_folder" "services" {
  provider = grafana.stack

  uid   = "cartergrove-me"
  title = "cartergrove.me"
}

# The "are the services OK?" dashboard. The JSON file is the dashboard: what
# Grafana's "Export" produces and what its API takes. Terraform only uploads
# it, and on every apply puts back whatever was changed in the UI. To change
# it, see "Changing the dashboard" in the README.
#
# The uid is inside the JSON ("services"), which keeps the URL the same when
# the dashboard is deleted and made again.
resource "grafana_dashboard" "services" {
  provider = grafana.stack

  folder      = grafana_folder.services.uid
  config_json = file("${path.module}/dashboards/services.json")

  # Replace a dashboard with the same uid instead of failing, e.g. one saved
  # from the UI before Terraform had made it.
  overwrite = true
}
