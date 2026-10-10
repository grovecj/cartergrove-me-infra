# Credentials come from environment variables only (never commit them):
#   DIGITALOCEAN_TOKEN                          - DO API token
#   SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY - for managing Spaces buckets
provider "digitalocean" {}

# The grafana provider is used for one thing here: this project's uptime
# checks. So it's configured for Synthetic Monitoring only, with the API URL
# and access token monitoring/ exports, not with Terraform's own Grafana Cloud
# token (GRAFANA_CLOUD_ACCESS_POLICY_TOKEN, which only monitoring/ needs).
# These come from state rather than the environment, so there's nothing to
# set, locally or in CI.
provider "grafana" {
  sm_url          = data.terraform_remote_state.monitoring.outputs.synthetic_monitoring_url
  sm_access_token = sensitive(data.terraform_remote_state.monitoring.outputs.synthetic_monitoring_access_token)
}
