# Monitoring for every *.cartergrove.me service, on Grafana Cloud's free tier.
# This root module is the plumbing: it finds the stack, makes the credentials
# services push telemetry with, and switches on Synthetic Monitoring (uptime
# checks) for the projects to declare their checks in. Dashboards and alerts
# are added here by later issues.
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
