# Credentials come from environment variables only (never commit them):
#   GRAFANA_CLOUD_ACCESS_POLICY_TOKEN - the token Terraform manages Grafana
#                                       Cloud with (bootstrap/README.md, step 7)
# This is the *administrator* credential: it can create access policies and
# tokens. It stays with Terraform (your shell, CI secrets) and is never given
# to a service. Services get the write-only token made in main.tf.
# The s3 backend still needs AWS_* to reach the state bucket; nothing here
# talks to DigitalOcean, so DIGITALOCEAN_TOKEN isn't used.
provider "grafana" {}

# A second configuration of the same provider, for what's *inside* the
# stack's Grafana: folders and dashboards. The one above talks to
# grafana.com (the account); this one talks to https://<slug>.grafana.net,
# and logs in as the service account made in main.tf. Resources pick it with
# `provider = grafana.stack`.
#
# The token comes from a resource in this same root, so on the very first
# plan it doesn't exist yet. That's fine: nothing in the stack exists yet
# either, so there's nothing for the provider to read until the apply has
# made the token. It's not fine later: a plan that replaces the token can't
# also plan what's in the stack (see the token in main.tf).
provider "grafana" {
  alias = "stack"

  url  = data.grafana_cloud_stack.main.url
  auth = grafana_cloud_stack_service_account_token.terraform.key
}
