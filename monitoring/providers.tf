# Credentials come from environment variables only (never commit them):
#   GRAFANA_CLOUD_ACCESS_POLICY_TOKEN - the token Terraform manages Grafana
#                                       Cloud with (bootstrap/README.md, step 7)
# This is the *administrator* credential: it can create access policies and
# tokens. It stays with Terraform (your shell, CI secrets) and is never given
# to a service. Services get the write-only token made in main.tf.
# The s3 backend still needs AWS_* to reach the state bucket; nothing here
# talks to DigitalOcean, so DIGITALOCEAN_TOKEN isn't used.
provider "grafana" {}
