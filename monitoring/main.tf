# Monitoring for every *.cartergrove.me service, on Grafana Cloud's free tier.
# This root module is the plumbing: it finds the stack and makes the
# credentials services push telemetry with. Dashboards, uptime checks and
# alerts are added here by later issues.
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
